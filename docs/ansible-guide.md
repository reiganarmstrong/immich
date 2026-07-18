# How this Ansible deployment works

This guide explains the repository's Ansible code for someone who has never
used Ansible. It covers the purpose of every file and follows the playbook in
the order Ansible executes it.

## The basic mental model

Ansible is a configuration-management tool. You describe the state a machine
should have, and Ansible connects to that machine and brings it toward that
state.

For this deployment, the desired state includes:

- Backup scripts installed in `/usr/local/sbin`.
- Root-owned configuration with restrictive permissions.
- A persistent state directory.
- Systemd service and timer files.
- A Docker shutdown-timeout override.
- Optionally, a dedicated AWS credentials file.
- A running and enabled backup timer.

Ansible is not the backup scheduler itself. Systemd performs the nightly
scheduling after Ansible installs it. Ansible also does not provision AWS in
this repository; Terraform owns the S3 bucket and IAM resources.

Four terms are important:

- **Controller:** The machine where you run `ansible-playbook`.
- **Target or managed host:** The machine Ansible configures.
- **Inventory:** The list of target machines and connection information.
- **Playbook:** The high-level instructions that select hosts and roles.

The controller and target happen to be the same PC in the included local
inventory example. They could be different machines later.

## Repository structure

```text
ansible/
├── ansible.cfg
├── deploy.yml
├── inventory.example.yml
├── vars.example.yml
└── roles/
    └── immich_s3_backup/
        ├── defaults/
        │   └── main.yml
        ├── handlers/
        │   └── main.yml
        ├── tasks/
        │   └── main.yml
        └── templates/
            ├── aws-credentials.j2
            ├── docker-timeout.conf.j2
            └── immich-s3-backup.env.j2
```

The files form a chain:

```text
inventory.yml
    identifies the machine
        ↓
deploy.yml
    selects that machine and invokes the role
        ↓
roles/immich_s3_backup/defaults/main.yml
    supplies default values
        ↓
vars.yml
    overrides deployment-specific defaults
        ↓
roles/immich_s3_backup/tasks/main.yml
    performs the installation in order
        ↓
templates/*.j2
    become concrete configuration files
        ↓
handlers/main.yml
    reloads systemd if relevant files changed
```

## YAML basics used here

YAML represents mappings, lists, strings, numbers, and booleans using
indentation.

A mapping associates names with values:

```yaml
ansible_host: localhost
ansible_connection: local
```

A list uses hyphens:

```yaml
immich_s3_backup_required_packages:
  - git
  - gzip
  - jq
```

Nested indentation expresses ownership. In this example, `hosts` belongs to
`immich_hosts`, and `immich` belongs to `hosts`:

```yaml
immich_hosts:
  hosts:
    immich:
```

The `---` at the top is the optional YAML document-start marker. It makes the
start explicit but does not change this playbook's behavior.

Quoted values such as `"0600"` remain strings. File modes are quoted because
leading zeroes have special numeric meanings in some YAML implementations.

## `ansible.cfg`: repository-wide Ansible behavior

The file starts with an INI section rather than YAML:

```ini
[defaults]
inventory = inventory.yml
interpreter_python = auto_silent
retry_files_enabled = False
roles_path = roles
```

Each setting has a specific purpose:

- `inventory = inventory.yml` makes the ignored real inventory the default.
  You can still override it with `-i another-file.yml`.
- `interpreter_python = auto_silent` asks Ansible to choose a suitable Python
  interpreter on the target without displaying routine discovery warnings.
- `retry_files_enabled = False` prevents old-style `.retry` files from being
  written after a failure.
- `roles_path = roles` tells Ansible where the local roles directory is.

The second section is:

```ini
[privilege_escalation]
become = True
```

`become` means that tasks should run with elevated privileges, normally through
`sudo`. Root access is required because the playbook writes to `/etc`,
`/usr/local`, `/var/lib`, and systemd directories. Add `-K` when the connecting
user must type a sudo password.

## `inventory.yml`: which machine receives the deployment

The tracked file is `inventory.example.yml`. You copy it to the ignored
`inventory.yml` before deployment.

```yaml
all:
  children:
    immich_hosts:
      hosts:
        immich:
          ansible_connection: local
          ansible_become_exe: /usr/bin/sudo.ws
          ansible_host: localhost
          ansible_python_interpreter: /usr/bin/python3
```

Read this from the outside inward:

- `all` is Ansible's built-in group containing every host.
- `children` defines groups nested beneath `all`.
- `immich_hosts` is the group used by this playbook.
- `hosts` starts the members of that group.
- `immich` is an arbitrary friendly name for this target.
- `ansible_connection: local` tells Ansible not to use SSH.
- `ansible_become_exe: /usr/bin/sudo.ws` selects Ubuntu's installed classic
  sudo implementation for Ansible. Ubuntu 26.04 uses `sudo-rs` by default, but
  its different password prompt is not compatible with Ansible's prompt
  detection on this host.
- `ansible_host: localhost` identifies the current machine.
- `ansible_python_interpreter` selects Python on the target.

For a remote machine, the host block could instead contain an address and SSH
user:

```yaml
immich:
  ansible_host: 192.168.1.50
  ansible_user: reagan
```

The real inventory is ignored because addresses, usernames, and internal DNS
names can reveal network details even though they are not passwords.

## `deploy.yml`: the playbook entry point

The playbook contains one **play**:

```yaml
- name: Deploy Immich S3 disaster-recovery backups
  hosts: immich_hosts
  become: true
  gather_facts: true

  roles:
    - role: immich_s3_backup
```

Line by line:

- `name` is a human-readable description displayed during execution.
- `hosts: immich_hosts` selects the inventory group described above.
- `become: true` requests root privileges for this play.
- `gather_facts: true` collects information about the target before tasks run.
  The role later uses facts such as operating-system family and init system.
- `roles` invokes the `roles/immich_s3_backup` directory.

The playbook intentionally stays small. The reusable and testable details live
inside the role.

## What an Ansible role is

A role is a conventional directory structure for one responsibility. Ansible
automatically recognizes files such as:

- `defaults/main.yml` for overridable default variables.
- `tasks/main.yml` for the ordered task list.
- `handlers/main.yml` for actions triggered only by changes.
- `templates/` for Jinja templates.

The role name is `immich_s3_backup`, so its variables use the
`immich_s3_backup_` prefix. The long prefix prevents collisions with variables
from other roles.

## Role defaults: the baseline configuration

`roles/immich_s3_backup/defaults/main.yml` contains safe defaults. Role
defaults have low precedence, so values supplied in `vars.yml` or with `-e`
override them.

### Repository location

```yaml
immich_s3_backup_repository_root: "{{ playbook_dir | dirname }}"
```

`playbook_dir` is an Ansible-provided variable pointing to the `ansible`
directory. `| dirname` is a Jinja filter that selects its parent,
`/srv/immich` in this checkout. Tasks use this path to find scripts, systemd
units, and documentation on the controller.

### AWS settings

```yaml
immich_s3_backup_aws_profile: immich-backup
immich_s3_backup_aws_region: us-east-1
immich_s3_backup_s3_bucket: ""
```

The profile and region have normal defaults. The bucket is deliberately empty,
forcing you to set the recovery bucket created by Terraform.

### Immich and PostgreSQL settings

```yaml
immich_s3_backup_compose_dir: /srv/immich
immich_s3_backup_upload_location: /srv/immich/library
immich_s3_backup_postgres_container: immich_postgres
immich_s3_backup_db_name: immich
immich_s3_backup_db_user: postgres
```

These tell the backup script where Immich lives and which container/database
to dump. The database password is not needed because `pg_dump` runs inside the
already configured PostgreSQL container.

### Timing and state settings

```yaml
immich_s3_backup_timezone: America/New_York
immich_s3_backup_state_dir: /var/lib/immich-s3-backup
immich_s3_backup_apt_wait_timeout_seconds: 7200
immich_s3_backup_postgres_wait_timeout_seconds: 900
```

The script interprets backup dates in New York time. It can wait up to two
hours for APT/dpkg and fifteen minutes for PostgreSQL. The state directory
contains locks, interrupted dump state, manifests, and success markers.

### Installation paths

```yaml
immich_s3_backup_config_file: /etc/immich-s3-backup.env
immich_s3_backup_credentials_file: /etc/immich-s3-backup.aws-credentials
immich_s3_backup_install_dir: /usr/local/sbin
immich_s3_backup_documentation_dir: /usr/local/share/doc/immich-s3-backup
```

These separate source files in Git from deployed files on the target. A Git
pull does not silently change the running backup; rerunning Ansible performs
the reviewed deployment.

### Credential controls

```yaml
immich_s3_backup_manage_aws_credentials: false
immich_s3_backup_aws_access_key_id: ""
immich_s3_backup_aws_secret_access_key: ""
immich_s3_backup_aws_session_token: ""
```

Credential management is off by default. When enabled, the access ID and
secret must be provided through the ignored `vars.yml`, preferably encrypted
with Ansible Vault. A session token is optional and normally blank for an IAM
user access key.

### Package list

```yaml
immich_s3_backup_manage_packages: true
immich_s3_backup_required_packages:
  - ca-certificates
  - findutils
  - git
  - gzip
  - jq
  - psmisc
  - python3-apt
  - util-linux
```

These packages supply tools used by the scripts or Ansible. Docker and AWS CLI
v2 are not automatically installed because replacing either is a larger host
administration decision. The role validates that they already exist.

### Feature switches

```yaml
immich_s3_backup_manage_docker_shutdown_timeout: true
immich_s3_backup_docker_shutdown_timeout: 15min
immich_s3_backup_enable_timer: true
immich_s3_backup_validate_aws_access: true
immich_s3_backup_run_backup_dry_run: false
```

These booleans turn optional behavior on or off. The playbook normally manages
the Docker timeout, validates AWS, and enables the timer. It does not scan the
media tree with the backup script unless the dry-run option is explicitly
enabled.

## `vars.yml`: deployment-specific overrides

You create `vars.yml` from `vars.example.yml`. The command line supplies it as
an extra-variable file:

```sh
ansible-playbook deploy.yml -e @vars.yml
```

The `@` means “read variables from this file.” Extra variables have very high
precedence, so these values override role defaults.

At minimum, set:

```yaml
immich_s3_backup_s3_bucket: your-real-recovery-bucket
```

If Ansible should install a dedicated credentials file, set the management
flag and credential values, then encrypt the file:

```sh
ansible-vault encrypt vars.yml
```

Ansible Vault encrypts the file at rest. Ansible decrypts it in memory after
you supply the Vault password. Vault does not create AWS credentials; it only
protects values you already created.

## How to read a task block

Most blocks in `tasks/main.yml` have this shape:

```yaml
- name: Human-readable task name
  ansible.builtin.module_name:
    option: value
  when: optional_condition
  changed_when: optional_change_rule
  notify: Optional handler name
```

- `name` explains the operation in output.
- The module performs the work. Modules are Ansible's built-in operations.
- `when` conditionally skips the task.
- `changed_when` tells Ansible whether an operation changed the host.
- `notify` schedules a handler if the task reports a change.

The fully qualified `ansible.builtin.*` names make it clear that these modules
come with Ansible Core rather than an external collection.

## Tasks, in execution order

Ansible runs `tasks/main.yml` from top to bottom.

### 1. Validate the target and variables

The first `ansible.builtin.assert` checks that:

- The target is Debian-family and uses systemd.
- The bucket name is present, within S3 length limits, and not the placeholder.
- Region, profile, paths, container name, database name, and database user use
  conservative character sets.

The expressions use Jinja tests and filters:

- `value | length` computes string length.
- `value is match('...')` checks a regular expression.
- `not in` rejects the known placeholder.

These checks fail early before the role writes files.

### 2. Validate optional AWS credentials

The second assertion runs only when:

```yaml
when: immich_s3_backup_manage_aws_credentials | bool
```

`| bool` interprets the variable as a boolean. If credential management is
enabled, both required values must be nonempty.

`no_log: true` suppresses task details so credentials cannot appear in Ansible
output or CI logs.

### 3. Install ordinary packages

The `ansible.builtin.apt` task ensures every listed package is present:

- `state: present` installs missing packages but does not reinstall existing
  ones.
- `update_cache: true` permits refreshing APT metadata.
- `cache_valid_time: 3600` reuses metadata refreshed within the last hour.

This task is skipped when package management is disabled.

### 4. Check external commands

The command task runs `aws --version`, `docker --version`, and
`systemd-inhibit --version` using a loop.

`item.command` and `item.argument` refer to fields in the current loop entry.
Using `argv` avoids shell parsing and quoting problems.

`changed_when: false` marks these as read-only checks. They execute commands
but do not change configuration. They are skipped in Ansible check mode.

### 5. Inspect and require host paths

`ansible.builtin.stat` inspects the Compose and upload directories. The result
is saved with:

```yaml
register: immich_s3_backup_host_paths
```

The next assertion loops over the saved results and requires each path to exist
and be a directory. `loop_control.label` keeps output readable by displaying
the path rather than the entire result object.

### 6. Check the PostgreSQL container

The role runs:

```text
docker inspect immich_postgres
```

This proves the configured container name exists. It does not restart or
modify the container. The backup script performs the more detailed health
wait when a backup actually runs.

### 7. Create runtime and documentation directories

The `ansible.builtin.file` module loops over directories and enforces:

- `state: directory` — the path exists as a directory.
- `owner: root` and `group: root` — root owns it.
- `mode` — the requested permissions are present.

Mode `0700` on the state directory means only root can read, write, or enter
it. Mode `0755` on documentation directories permits everyone to read them but
only root to modify them.

### 8. Install the commands

The `ansible.builtin.copy` module copies the tracked shell scripts from the
controller into `/usr/local/sbin` on the target. The `.sh` suffix is removed
from the installed command names.

Mode `0755` makes the scripts executable. Ansible compares content and copies
only when necessary.

### 9. Install documentation

Another copy loop installs the Ansible, Terraform, deployment, and recovery
documents while retaining their relative directory structure. That is why the
systemd unit's path is:

```text
/usr/local/share/doc/immich-s3-backup/docs/disaster-recovery.md
```

The copy is skipped in check mode because the parent directory may only be
scheduled—not actually created—during that preview run.

### 10. Optionally install AWS credentials

`ansible.builtin.template` renders `aws-credentials.j2` into the dedicated
credentials file. It runs only when credential management is enabled.

Mode `0600` means only root can read or write the file. `no_log: true` also
protects rendered values from output. Ansible does not put these credentials
in Terraform state.

### 11. Install the backup environment

The next template task renders `immich-s3-backup.env.j2` to
`/etc/immich-s3-backup.env` with root ownership and mode `0600`.

This file contains operational configuration such as paths, bucket name, and
timeouts. It does not contain the PostgreSQL password. It contains the path to
the AWS credentials file only when Ansible manages that file.

### 12. Manage Docker's shutdown timeout

The role creates `/etc/systemd/system/docker.service.d` and renders a systemd
drop-in there. The drop-in gives Docker fifteen minutes to stop gracefully,
which exceeds Immich's ten-minute container shutdown allowance.

The template task uses:

```yaml
notify: Reload systemd
```

The handler is notified only if the rendered file changes.

### 13. Install the backup systemd units

The service and timer from the repository are copied to
`/etc/systemd/system`. A loop handles both files. Changes also notify the
systemd reload handler.

Copying the units does not itself enable or start the timer.

### 14. Flush handlers

Handlers normally run at the end of a play. This task forces pending handlers
to run immediately:

```yaml
ansible.builtin.meta: flush_handlers
```

That guarantees systemd has reread new unit files before the role tries to
verify or enable them.

### 15. Verify systemd units

`systemd-analyze verify` checks the installed service and timer for invalid
directives and dependency problems. `changed_when: false` marks this as a
validation step. It is skipped during check mode because the files may not yet
exist there.

### 16. Validate the AWS identity

The first AWS validation runs `sts get-caller-identity`. It proves that the
selected profile contains usable credentials.

The `environment` expression passes `AWS_SHARED_CREDENTIALS_FILE` only when
Ansible manages the dedicated file. Otherwise the AWS CLI uses root's normal
profile location.

This task uses `no_log: true` to keep account and credential-related details
out of playbook output. It is read-only and skipped in check mode.

### 17. Validate recovery-bucket access

The second AWS validation runs `s3api get-bucket-location`. It verifies that
the backup identity can reach the exact configured bucket before the timer is
enabled. It uses the same conditional credential environment and log
suppression.

### 18. Optionally exercise backup dry-run behavior

When explicitly enabled, the role invokes the installed backup command with
`--dry-run`. This validates Docker, PostgreSQL, AWS, and the media sync plan.
The script does not create a database dump, upload objects, or write a success
marker in this mode, but scanning a large media tree can take time.

### 19. Enable and start the timer

The final `ansible.builtin.systemd_service` task controls
`immich-s3-backup.timer`:

- `enabled: true` starts it automatically on future boots.
- `state: started` starts the timer now.
- Setting the feature variable false instead disables and stops the timer.

This task is last so invalid configuration or AWS access prevents activation.
Starting the timer does not immediately force a real backup; systemd schedules
the configured activation time.

## Handlers

`handlers/main.yml` defines:

```yaml
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

A handler is a task that runs only after another changed task notifies it.
Multiple changed tasks can notify the same handler, but Ansible normally runs
it once. This avoids unnecessary repeated `systemctl daemon-reload` calls.

The handler is skipped in check mode because a preview should not change
systemd's live manager state.

## Jinja templates

Jinja turns variable-containing source text into concrete target files.

### Backup environment template

Expressions such as:

```jinja2
S3_BUCKET={{ immich_s3_backup_s3_bucket }}
```

insert the current variable value. The conditional block:

```jinja2
{% if immich_s3_backup_manage_aws_credentials %}
AWS_SHARED_CREDENTIALS_FILE={{ immich_s3_backup_credentials_file }}
{% endif %}
```

includes that line only in managed-credential mode.

### AWS credentials template

The profile name appears in square brackets because that is AWS's credentials
file format. The session-token line is emitted only when a nonempty token is
provided.

The tracked template contains placeholders, never real credentials. The
rendered file exists only on the target.

### Docker timeout template

This template is a small systemd drop-in:

```jinja2
[Service]
TimeoutStopSec={{ immich_s3_backup_docker_shutdown_timeout }}
```

With defaults, it becomes `TimeoutStopSec=15min`.

## Idempotence: why rerunning is safe

Ansible modules generally inspect current state before changing it. For
example:

- `apt` leaves already installed packages alone.
- `file` leaves correct directories and permissions alone.
- `copy` compares file content before replacing it.
- `template` compares rendered output before replacing it.
- `systemd_service` leaves an already enabled, running timer in that state.

Therefore, a second playbook run should report mostly `ok` rather than
`changed`. The playbook does not delete S3 objects, clear backup state, recreate
the database, or start a real backup.

## Check mode versus a real run

This command previews changes:

```sh
ansible-playbook deploy.yml -e @vars.yml --check --diff
```

- `--check` asks supporting modules to predict changes without applying them.
- `--diff` displays safe textual file differences.

Tasks requiring files that do not yet exist, live AWS calls, systemd reloads,
or Docker commands are deliberately skipped in check mode. A successful check
run is useful but is not proof that credentials or external services work.
The real playbook run performs those validations.

Credential template tasks use `no_log`, so secrets are not shown even with
`--diff`.

## Understanding Ansible output

Each task ends with a status:

- `ok` — the desired state already existed or a read-only check passed.
- `changed` — Ansible changed the target or predicts a change in check mode.
- `skipping` — a `when` condition was false.
- `failed` — the task could not meet its requirement; later tasks stop for that
  host.
- `unreachable` — Ansible could not connect to the target.

The final recap totals these statuses for every host.

## Commands you will normally use

Prepare ignored local files:

```sh
cp inventory.example.yml inventory.yml
cp vars.example.yml vars.yml
$EDITOR inventory.yml vars.yml
```

Validate syntax:

```sh
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --syntax-check
```

Preview:

```sh
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --check --diff
```

Deploy:

```sh
ansible-playbook -i inventory.yml deploy.yml -e @vars.yml
```

For an encrypted variables file, append `--ask-vault-pass`. For sudo requiring
a password, append `--ask-become-pass` or `-K`.

Increase verbosity while troubleshooting:

```sh
ansible-playbook -i inventory.yml deploy.yml -e @vars.yml -vv
```

Avoid very high verbosity around secret-bearing workflows unless needed, even
though the sensitive tasks use `no_log`.

## What happens after Ansible finishes

Ansible exits. Systemd then owns routine operation:

1. `immich-s3-backup.timer` waits for 04:00 America/New_York.
2. At activation, it starts `immich-s3-backup.service`.
3. The service uses `systemd-inhibit` to block ordinary shutdown and sleep.
4. The installed backup script waits for APT and PostgreSQL.
5. It dumps PostgreSQL, uploads database recovery points, syncs media, and
   writes a manifest.
6. Systemd records output in the journal and applies the retry policy on
   failure.

To inspect that later:

```sh
systemctl list-timers immich-s3-backup.timer
sudo systemctl status immich-s3-backup.timer
sudo journalctl -u immich-s3-backup.service
```

## Responsibility boundaries

It helps to remember which tool owns which layer:

| Layer | Owner |
| --- | --- |
| S3 bucket, lifecycle, Object Lock, IAM policy/user | Terraform |
| IAM access-key creation | AWS administrator/manual workflow |
| Secret storage at rest | Password manager and optionally Ansible Vault |
| Packages, installed scripts, configuration, units | Ansible |
| Nightly scheduling and retries | systemd |
| Database dump and S3 transfers | Shell backup script and AWS CLI |
| Immich application runtime | Docker Compose |

This separation is intentional. Rerunning a host deployment cannot silently
alter the recovery bucket, and running Terraform cannot place an access-key
secret into state.
