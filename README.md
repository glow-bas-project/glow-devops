# glow-devops

# Keycloak

## 1. Setting up Keycloak locally

Prerequisites differ slightly 
between Windows and macOS.

### Prerequisites

**Windows 11:**
- Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/)
- Ensure WSL 2 is enabled (Docker Desktop will prompt you if not)
- Use PowerShell or Windows Terminal for all commands

**macOS:**
- Install [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/)
- Use Terminal or iTerm2 for all commands

Once Docker Desktop is installed, make sure it is **running** before proceeding 
(you should see the Docker whale icon in your taskbar/menu bar).

### Steps

1. Clone the `glow-devops` repository and open a terminal in its root directory 
   (where `docker-compose.yml` is located)
2. Run Keycloak:
```bash
   docker compose up
```
   Wait until you see `Keycloak 26.0.8 ... started` in the terminal output before 
   proceeding. First run will take longer as Docker pulls the image.

3. The realm, roles, and clients are imported automatically from 
   `keycloak/realm-export.json` – no manual admin UI configuration is needed.
4. Verify the setup by requesting a test token (see Section 3).

> **Note:** `glow-devops` contains shared infrastructure only. Each microservice 
> has its own repository and connects to this locally running Keycloak instance 
> during development.

## 2. Keycloak setup details

- **Image**: `quay.io/keycloak/keycloak:26.0.8`
- **Mode**: `start-dev` (development only – no TLS, embedded H2 database)
- **Admin credentials**: `admin / admin` (local dev only, never used in production)
- **Realm**: `glow-realm`
- **Roles**: `CUSTOMER`, `COURIER`, `RESTAURANT_USER`, `SYSADMIN`
- **Clients**: `glow-frontend` (public), `glow-user-service` (confidential)
- **Realm config**: committed to `keycloak/realm-export.json`, auto-imported on 
  container startup via `--import-realm`

## 3. Running Keycloak locally

Keycloak will be available at http://localhost:8080. The realm, roles, and clients are 
imported automatically from _keycloak/realm-export.json_. No manual admin UI configuration 
is needed after the initial setup.

Admin console: http://localhost:8080/admin (`admin / admin`)  
Token endpoint: `http://localhost:8080/realms/glow-realm/protocol/openid-connect/token`

### Verifying the setup (Optional)

Request a token for the test user. Note the OS difference in curl usage:

**Windows (PowerShell):**
```powershell
curl.exe -X POST http://localhost:8080/realms/glow-realm/protocol/openid-connect/token `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "grant_type=password" `
  -d "client_id=glow-frontend" `
  -d "username=testcustomer" `
  -d "password=test123"
```

**macOS (Terminal):**
```bash
curl -X POST http://localhost:8080/realms/glow-realm/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=glow-frontend" \
  -d "username=testcustomer" \
  -d "password=test123"
```

A successful response contains an `access_token` field. The token is a JWT with three 
parts separated by dots (`header.payload.signature`) – copy the **entire string** and 
paste it into [jwt.io](https://jwt.io) to inspect it. Under **Payload** you should see:
```json
"realm_access": {
  "roles": ["CUSTOMER"]
}
```

This confirms Keycloak is correctly issuing tokens with the right role assigned.

---
---

# Getting started

To make it easy for you to get started with GitLab, here's a list of recommended next steps.

Already a pro? Just edit this README.md and make it your own. Want to make it easy? [Use the template at the bottom](#editing-this-readme)!

## Add your files

* [Create](https://docs.gitlab.com/user/project/repository/web_editor/#create-a-file) or [upload](https://docs.gitlab.com/user/project/repository/web_editor/#upload-a-file) files
* [Add files using the command line](https://docs.gitlab.com/topics/git/add_files/#add-files-to-a-git-repository) or push an existing Git repository with the following command:

```
cd existing_repo
git remote add origin https://gitlab.au.dk/backend-architecture-and-scalability/glow-devops.git
git branch -M main
git push -uf origin main
```

## Integrate with your tools

* [Set up project integrations](https://gitlab.au.dk/backend-architecture-and-scalability/glow-devops/-/settings/integrations)

## Collaborate with your team

* [Invite team members and collaborators](https://docs.gitlab.com/user/project/members/)
* [Create a new merge request](https://docs.gitlab.com/user/project/merge_requests/creating_merge_requests/)
* [Automatically close issues from merge requests](https://docs.gitlab.com/user/project/issues/managing_issues/#closing-issues-automatically)
* [Enable merge request approvals](https://docs.gitlab.com/user/project/merge_requests/approvals/)
* [Set auto-merge](https://docs.gitlab.com/user/project/merge_requests/auto_merge/)

## Test and Deploy

Use the built-in continuous integration in GitLab.

* [Get started with GitLab CI/CD](https://docs.gitlab.com/ci/quick_start/)
* [Analyze your code for known vulnerabilities with Static Application Security Testing (SAST)](https://docs.gitlab.com/user/application_security/sast/)
* [Deploy to Kubernetes, Amazon EC2, or Amazon ECS using Auto Deploy](https://docs.gitlab.com/topics/autodevops/requirements/)
* [Use pull-based deployments for improved Kubernetes management](https://docs.gitlab.com/user/clusters/agent/)
* [Set up protected environments](https://docs.gitlab.com/ci/environments/protected_environments/)

***

# Editing this README

When you're ready to make this README your own, just edit this file and use the handy template below (or feel free to structure it however you want - this is just a starting point!). Thanks to [makeareadme.com](https://www.makeareadme.com/) for this template.

## Suggestions for a good README

Every project is different, so consider which of these sections apply to yours. The sections used in the template are suggestions for most open source projects. Also keep in mind that while a README can be too long and detailed, too long is better than too short. If you think your README is too long, consider utilizing another form of documentation rather than cutting out information.

## Name
Choose a self-explaining name for your project.

## Description
Let people know what your project can do specifically. Provide context and add a link to any reference visitors might be unfamiliar with. A list of Features or a Background subsection can also be added here. If there are alternatives to your project, this is a good place to list differentiating factors.

## Badges
On some READMEs, you may see small images that convey metadata, such as whether or not all the tests are passing for the project. You can use Shields to add some to your README. Many services also have instructions for adding a badge.

## Visuals
Depending on what you are making, it can be a good idea to include screenshots or even a video (you'll frequently see GIFs rather than actual videos). Tools like ttygif can help, but check out Asciinema for a more sophisticated method.

## Installation
Within a particular ecosystem, there may be a common way of installing things, such as using Yarn, NuGet, or Homebrew. However, consider the possibility that whoever is reading your README is a novice and would like more guidance. Listing specific steps helps remove ambiguity and gets people to using your project as quickly as possible. If it only runs in a specific context like a particular programming language version or operating system or has dependencies that have to be installed manually, also add a Requirements subsection.

## Usage
Use examples liberally, and show the expected output if you can. It's helpful to have inline the smallest example of usage that you can demonstrate, while providing links to more sophisticated examples if they are too long to reasonably include in the README.

## Support
Tell people where they can go to for help. It can be any combination of an issue tracker, a chat room, an email address, etc.

## Roadmap
If you have ideas for releases in the future, it is a good idea to list them in the README.

## Contributing
State if you are open to contributions and what your requirements are for accepting them.

For people who want to make changes to your project, it's helpful to have some documentation on how to get started. Perhaps there is a script that they should run or some environment variables that they need to set. Make these steps explicit. These instructions could also be useful to your future self.

You can also document commands to lint the code or run tests. These steps help to ensure high code quality and reduce the likelihood that the changes inadvertently break something. Having instructions for running tests is especially helpful if it requires external setup, such as starting a Selenium server for testing in a browser.

## Authors and acknowledgment
Show your appreciation to those who have contributed to the project.

## License
For open source projects, say how it is licensed.

## Project status
If you have run out of energy or time for your project, put a note at the top of the README saying that development has slowed down or stopped completely. Someone may choose to fork your project or volunteer to step in as a maintainer or owner, allowing your project to keep going. You can also make an explicit request for maintainers.
