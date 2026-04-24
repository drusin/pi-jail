# pi-jail

Run the [pi coding agent](https://pi.dev/) inside a disposable Docker container while keeping your current project mounted as the working directory.

`pi-jail` gives you a simple, repeatable way to use pi with:

- an isolated container environment
- your current folder mounted into `/workspace/<project-name>`
- persistent pi config in `~/.pi`
- optional API keys and Git identity loaded from `pi-jail.env`
- Possibility to call explicilty selected binaries from the host, see [below](#host-command-forwarding-mvp)

## Setup
- build the image with `docker build -t pi-jail .`
- put your os-spefic script somewhere in your PATH
- *optional* create `pi-jail.env` next to the script based on the example to load API keys and Git identity
  - If you want to use pi's internal login command, you don't need to put API keys in the env file
  - Put `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` in the env file if you want pi to be able to make commits (pushing is not supported by design)
  - On Windows, run `pi-jail.ps1` from PowerShell 7 (`pwsh`); Windows PowerShell 5 is not supported
  - On Windows or Linux, set `RUN_ON_HOST=<command>` to forward selected top-level commands from the container to the host; the command runs on the host in the folder where the launcher was started

## Daily use
- navigate to a project folder on your host machine
- run `pi-jail` from there
- any arguments you pass to `pi-jail` are forwarded to `pi` inside the container, except launcher flags like `--no-workspace` and `--run-on-host=<command>`
  - example: `pi-jail -r` runs `pi -r` in the container, which starts pi with an interactive session browser
- use pi (assuming you have an llm provider set up)

## Set up dev enironments:
- Node
- Java
- Python 3

## Host-command forwarding MVP
- set `RUN_ON_HOST` in `pi-jail.env`, for example `RUN_ON_HOST=git`
- you can also add ad-hoc forwarded commands per run with `--run-on-host=<command>`
- env and CLI values are merged, so `RUN_ON_HOST=npm,mvn` plus `--run-on-host=curl` forwards `npm`, `mvn`, and `curl`
- start `pi-jail.ps1` or `pi-jail.sh` from the project folder you want host commands to run in
- inside the container, calls to the listed commands are forwarded to the host
- current limitations:
  - no path translation
  - forwarded commands always run in the host folder where the launcher was started
  - on Linux, the launcher currently requires `perl` on the host when `RUN_ON_HOST` is enabled
  - on Windows, the launcher requires PowerShell 7 (`pwsh`)
