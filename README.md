# pi-jail

Run the [pi coding agent](https://[www.npmjs.com/package/@mariozechner/pi-coding-agent](https://pi.dev/) inside a disposable Docker container while keeping your current project mounted as the working directory.

`pi-jail` gives you a simple, repeatable way to use pi with:

- an isolated container environment
- your current folder mounted into `/workspace/<project-name>`
- persistent pi config in `~/.pi`
- optional API keys and Git identity loaded from `pi-jail.env`
- Linux/Unix and Windows launch scripts

## Setup
- build the image with `docker build -t pi-jail .`
- put your os-spefic script somewhere in your PATH
- *optional* create `pi-jail.env` next to the script based on the example to load API keys and Git identity
  - If you want to use pi's internal login command, you don't need to put API keys in the env file
  - Put `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` in the env file if you want pi to be able to make commits (pushing is not supported by design)

## Daily use
- navigate to a project folder on your host machine
- run `pi-jail` from there
- use pi (assuming you have an llm provider set up)

## Set up dev enironments:
- Node
- Java
