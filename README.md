# pi-jail

Run the [pi coding agent](https://pi.dev/) inside a disposable Docker container while keeping your current project mounted as the working directory.

`pi-jail` gives you a simple, repeatable way to use pi with:

- an isolated container environment
- your current folder mounted into `/workspace/<project-name>`
- persistent pi config in `~/.pi`
- optional API keys, Git identity, and port publishing loaded from `pi-jail.env` or via `-p`
- all bound ports are passed into the container as `EXPOSED_PORTS`
- Linux/Unix and Windows launch scripts

## Setup
- build the image with `docker build -t pi-jail .`
- put your os-spefic script somewhere in your PATH
- *optional* create `pi-jail.env` next to the script based on the example to load API keys and Git identity
  - If you want to use pi's internal login command, you don't need to put API keys in the env file
  - Put `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` in the env file if you want pi to be able to make commits (pushing is not supported by design)
  - Put `PORTS=8888,9999` in the env file to publish `8888:8888` and `9999:9999`
  - Put `RANDOM_PORT=true` in `pi-jail.env` to publish one random free port starting at `9000`
  - Pass `-p 7777` to also publish `7777:7777`; you can repeat `-p` or use comma-separated values
  - Pass `-p` without a value to publish one random free port starting at `9000`
  - Ports from `PORTS`, `RANDOM_PORT`, and `-p` are combined
  - Ports are only bound if they are free on the host; busy ports are skipped with a warning
  - Inside the container, `EXPOSED_PORTS` contains the successfully bound ports as a comma-separated list
  - On Windows, set `RUN_ON_HOST=npm` (or similar) to forward selected top-level commands from the container to the host; the command runs on the host in the folder where `pi-jail.ps1` was started

## Daily use
- navigate to a project folder on your host machine
- run `pi-jail` from there
- any arguments you pass to `pi-jail` are forwarded to `pi` inside the container, except launcher flags like `--no-workspace` and `-p`
  - examples:
    - `pi-jail -p 7777`
    - `pi-jail -p 7777,8888`
    - `pi-jail -p -r` to allocate one random port and start `pi -r`
  - example: `pi-jail -r` runs `pi -r` in the container, which starts pi with an interactive session browser
- use pi (assuming you have an llm provider set up)

## Set up dev enironments:
- Node
- Java

## Windows host-command forwarding MVP
- set `RUN_ON_HOST` in `pi-jail.env`, for example `RUN_ON_HOST=npm`
- start `pi-jail.ps1` from the project folder you want host commands to run in
- inside the container, calls to the listed commands are forwarded to the host
- current limitations:
  - Windows launcher only
  - no path translation
  - forwarded commands always run in the host folder where `pi-jail.ps1` was started
