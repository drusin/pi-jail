#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="pi-jail"
ENV_FILE="${SCRIPT_DIR}/pi-jail.env"

host_exec_pid=""
host_exec_script_path=""

cleanup() {
    if [ -n "${host_exec_pid}" ] && kill -0 "${host_exec_pid}" 2>/dev/null; then
        kill "${host_exec_pid}" 2>/dev/null || true
        wait "${host_exec_pid}" 2>/dev/null || true
    fi

    if [ -n "${host_exec_script_path}" ] && [ -f "${host_exec_script_path}" ]; then
        rm -f "${host_exec_script_path}"
    fi
}
trap cleanup EXIT

get_env_value() {
    local path="$1"
    local name="$2"
    local value

    value="$({
        grep -E "^[[:space:]]*${name}[[:space:]]*=" "${path}" || true
    } | head -n 1 | sed -E "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*//")"

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "${value}"
}

new_host_exec_token() {
    head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
}

get_free_tcp_port() {
    perl -MIO::Socket::INET -e '
        my $socket = IO::Socket::INET->new(
            LocalAddr => "127.0.0.1",
            LocalPort => 0,
            Proto     => "tcp",
            Listen    => 1,
            ReuseAddr => 1,
        ) or die $!;
        print $socket->sockport;
    '
}

wait_host_exec_server() {
    local port="$1"
    local pid="$2"
    local timeout_seconds="${3:-5}"
    local deadline=$((SECONDS + timeout_seconds))

    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo "[pi-jail] Host exec server exited unexpectedly." >&2
            return 1
        fi

        if (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.1
    done

    echo "[pi-jail] Timed out waiting for host exec server on port ${port}." >&2
    return 1
}

write_host_exec_server() {
    local path="$1"

    cat > "${path}" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use MIME::Base64 qw(decode_base64 encode_base64);

my ($port, $token, $workspace);
GetOptions(
    'port=i'     => \$port,
    'token=s'    => \$token,
    'workspace=s'=> \$workspace,
) or die "Invalid arguments\n";

die "Missing --port\n" unless defined $port;
die "Missing --token\n" unless defined $token;
die "Missing --workspace\n" unless defined $workspace;

sub encode_value {
    my ($value) = @_;
    $value = '' unless defined $value;
    return encode_base64($value, '');
}

sub decode_value {
    my ($value) = @_;
    $value = '' unless defined $value;
    return decode_base64($value);
}

sub send_frame {
    my ($writer, $type, $value) = @_;
    if (defined $value && length $value) {
        print {$writer} "$type $value\n";
    } else {
        print {$writer} "$type\n";
    }
    $writer->flush();
}

sub send_data {
    my ($writer, $type, $data) = @_;
    send_frame($writer, $type, encode_value($data));
}

sub read_request {
    my ($reader) = @_;
    my $request_token;
    my $command;
    my @arguments;
    my $saw_frames = 0;

    while (my $line = <$reader>) {
        $line =~ s/\r?\n\z//;
        next if $line eq '';
        last if $line eq 'END';
        $saw_frames = 1;

        my ($type, $value) = $line =~ /^(\S+)(?:\s(.*))?\z/;
        $value = '' unless defined $value;

        if ($type eq 'TOKEN') {
            $request_token = decode_value($value);
        } elsif ($type eq 'COMMAND') {
            $command = decode_value($value);
        } elsif ($type eq 'ARG') {
            push @arguments, decode_value($value);
        } else {
            die "Invalid host exec frame type: $type\n";
        }
    }

    return undef if !$saw_frames && eof($reader);

    return {
        token     => $request_token,
        command   => $command,
        arguments => \@arguments,
    };
}

sub resolve_command {
    my ($command) = @_;
    return undef unless defined $command && length $command;

    if ($command =~ m{/}) {
        return (-f $command && -x _) ? $command : undef;
    }

    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $candidate = "$dir/$command";
        return $candidate if -f $candidate && -x _;
    }

    return undef;
}

sub exec_resolved_command {
    my ($command, @arguments) = @_;
    exec { $command } $command, @arguments;
}

sub invoke_host_command {
    my ($writer, $request_token, $request_command, $arguments_ref) = @_;

    if (!defined $request_token || $request_token ne $token) {
        send_data($writer, 'STDERR', "Unauthorized host exec request\n");
        send_frame($writer, 'EXIT', '126');
        return;
    }

    if (!defined $request_command || $request_command !~ /\S/) {
        send_data($writer, 'STDERR', "Missing host exec command\n");
        send_frame($writer, 'EXIT', '125');
        return;
    }

    my $resolved_command = resolve_command($request_command);
    if (!defined $resolved_command) {
        send_data($writer, 'STDERR', "Command not found: $request_command\n");
        send_frame($writer, 'EXIT', '127');
        return;
    }

    pipe(my $stdout_reader, my $stdout_writer) or do {
        send_data($writer, 'STDERR', "$!\n");
        send_frame($writer, 'EXIT', '127');
        return;
    };
    pipe(my $stderr_reader, my $stderr_writer) or do {
        close $stdout_reader;
        close $stdout_writer;
        send_data($writer, 'STDERR', "$!\n");
        send_frame($writer, 'EXIT', '127');
        return;
    };

    my $pid = fork();
    if (!defined $pid) {
        close $stdout_reader;
        close $stdout_writer;
        close $stderr_reader;
        close $stderr_writer;
        send_data($writer, 'STDERR', "$!\n");
        send_frame($writer, 'EXIT', '127');
        return;
    }

    if ($pid == 0) {
        close $stdout_reader;
        close $stderr_reader;

        open STDIN, '<', '/dev/null' or exit 127;
        open STDOUT, '>&', $stdout_writer or exit 127;
        open STDERR, '>&', $stderr_writer or exit 127;

        close $stdout_writer;
        close $stderr_writer;

        chdir $workspace or do {
            print STDERR "$!\n";
            exit 127;
        };

        exec_resolved_command($resolved_command, @{$arguments_ref});
        print STDERR "$!\n";
        exit 127;
    }

    close $stdout_writer;
    close $stderr_writer;

    my $selector = IO::Select->new($stdout_reader, $stderr_reader);
    while (my @ready = $selector->can_read) {
        for my $handle (@ready) {
            my $line = <$handle>;
            if (defined $line) {
                my $type = ($handle == $stdout_reader) ? 'STDOUT' : 'STDERR';
                send_data($writer, $type, $line);
            } else {
                $selector->remove($handle);
                close $handle;
            }
        }
    }

    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    send_frame($writer, 'EXIT', "$exit_code");
}

my $server = IO::Socket::INET->new(
    LocalAddr => '0.0.0.0',
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or die "$!\n";

while (my $client = $server->accept()) {
    $client->autoflush(1);
    eval {
        my $request = read_request($client);
        if (defined $request) {
            invoke_host_command(
                $client,
                $request->{token},
                $request->{command},
                $request->{arguments},
            );
        }
        1;
    } or do {
        send_data($client, 'STDERR', "Invalid host exec request\n");
        send_frame($client, 'EXIT', '125');
    };
    close $client;
}
PL

    chmod +x "${path}"
}

# ── Build image if not present ───────────────────────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "[pi-jail] Building image '${IMAGE_NAME}'..."
    docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
fi

# ── Parse command line arguments ─────────────────────────────────────────────
NO_WORKSPACE=false
ad_hoc_run_on_host_values=()
filtered_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-workspace)
            NO_WORKSPACE=true
            shift
            ;;
        --run-on-host=*)
            ad_hoc_run_on_host_values+=("${1#--run-on-host=}")
            shift
            ;;
        --run-on-host)
            if [[ $# -lt 2 ]]; then
                echo "[pi-jail] Error: --run-on-host requires a value." >&2
                exit 1
            fi
            ad_hoc_run_on_host_values+=("$2")
            shift 2
            ;;
        *)
            filtered_args+=("$1")
            shift
            ;;
    esac
done
set -- "${filtered_args[@]}"

# ── Resolve workspace: mount current folder under /workspace/<dirname> ──────
WORKSPACE="${PWD}"
FOLDER_NAME="$(basename "${WORKSPACE}")"
if [ "${NO_WORKSPACE}" = "true" ]; then
    CONTAINER_WORKDIR="/home/user"
else
    CONTAINER_WORKDIR="/workspace/${FOLDER_NAME}"
fi
CONTAINER_SUFFIX="$(printf '%s' "${FOLDER_NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
CONTAINER_SUFFIX="${CONTAINER_SUFFIX:-workspace}"
CONTAINER_NAME="pi-jail-${CONTAINER_SUFFIX}"

if docker container inspect "${CONTAINER_NAME}" &>/dev/null; then
    CONTAINER_RUNNING="$(docker container inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")"
    if [ "${CONTAINER_RUNNING}" = "true" ]; then
        echo "[pi-jail] Error: container '${CONTAINER_NAME}' is already running." >&2
        exit 1
    fi

    echo "[pi-jail] Removing stopped container '${CONTAINER_NAME}'..."
    docker rm "${CONTAINER_NAME}" >/dev/null
fi

# ── Ensure ~/.pi exists on host and is owned by current user ─────────────────
PI_DIR="${HOME}/.pi"
mkdir -p "${PI_DIR}"

# ── Match container user to current host user (helps git ownership checks) ──
LOCAL_UID="$(id -u)"
LOCAL_GID="$(id -g)"

# ── Base docker run args ─────────────────────────────────────────────────────
docker_args=(
    run
    --rm
    -it
    --name "${CONTAINER_NAME}"
    --user "${LOCAL_UID}:${LOCAL_GID}"
    --add-host host.docker.internal=host-gateway
    -e "HOST_SYSTEM=linux"
)
if [ "${NO_WORKSPACE}" = "false" ]; then
    docker_args+=(-v "${WORKSPACE}:${CONTAINER_WORKDIR}")
fi
docker_args+=(
    -v "${PI_DIR}:/home/user/.pi"
    -w "${CONTAINER_WORKDIR}"
)

run_on_host_value=""
if [ -f "${ENV_FILE}" ]; then
    echo "[pi-jail] Loading env from pi-jail.env"
    docker_args+=(--env-file "${ENV_FILE}")
    run_on_host_value="$(get_env_value "${ENV_FILE}" "RUN_ON_HOST")"
else
    echo "[pi-jail] No pi-jail.env found, skipping."
fi

run_on_host_commands=()
append_system_prompt=""
add_run_on_host_commands() {
    local raw_value="$1"
    local command
    local existing_command
    local already_present

    [ -z "${raw_value}" ] && return 0

    IFS=',' read -r -a raw_run_on_host_commands <<< "${raw_value}"
    for command in "${raw_run_on_host_commands[@]}"; do
        command="$(printf '%s' "${command}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -z "${command}" ] && continue

        already_present=false
        for existing_command in "${run_on_host_commands[@]}"; do
            if [ "${existing_command}" = "${command}" ]; then
                already_present=true
                break
            fi
        done

        if [ "${already_present}" = "false" ]; then
            run_on_host_commands+=("${command}")
        fi
    done
}

add_run_on_host_commands "${run_on_host_value}"
for ad_hoc_run_on_host_value in "${ad_hoc_run_on_host_values[@]}"; do
    add_run_on_host_commands "${ad_hoc_run_on_host_value}"
done

if [ "${#run_on_host_commands[@]}" -gt 0 ]; then
    run_on_host_joined="$(IFS=,; printf '%s' "${run_on_host_commands[*]}")"
    docker_args+=(-e "RUN_ON_HOST=${run_on_host_joined}")
    append_system_prompt="Commands listed in RUN_ON_HOST (${run_on_host_joined}) are executed directly on the Linux host, not inside the container. When using those commands, assume the host environment, installed tools, credentials, filesystem, and environment variables may differ from the container. For all other commands, assume the normal container environment."

    if ! command -v perl >/dev/null 2>&1; then
        echo "[pi-jail] Error: RUN_ON_HOST requires perl on the Linux host." >&2
        exit 1
    fi

    host_exec_port="$(get_free_tcp_port)"
    host_exec_token="$(new_host_exec_token)"
    host_exec_script_path="$(mktemp "${TMPDIR:-/tmp}/pi-jail-host-exec-XXXXXX.pl")"

    write_host_exec_server "${host_exec_script_path}"
    perl "${host_exec_script_path}" \
        --port "${host_exec_port}" \
        --token "${host_exec_token}" \
        --workspace "${WORKSPACE}" &
    host_exec_pid="$!"

    wait_host_exec_server "${host_exec_port}" "${host_exec_pid}"
    docker_args+=(
        -e "PI_HOST_EXEC_HOST=host.docker.internal"
        -e "PI_HOST_EXEC_PORT=${host_exec_port}"
        -e "PI_HOST_EXEC_TOKEN=${host_exec_token}"
    )
fi

echo "[pi-jail] Starting pi in: ${CONTAINER_WORKDIR}"
pi_args=()
if [ -n "${append_system_prompt}" ]; then
    pi_args+=(--append-system-prompt "${append_system_prompt}")
fi
pi_args+=("$@")
docker "${docker_args[@]}" "${IMAGE_NAME}" pi "${pi_args[@]}"
