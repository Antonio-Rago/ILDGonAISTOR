# openlat on ucloud: Usage and Administration

Oct 2, 2026 · Antonio (with the help of Claude)

## Overview

The `openlat` bucket is private: data is reached either through an IAM-ILDG login that can download only files tagged `ildg_download=true`, or through a local AIStor user in one of two groups. The server is MinIO AIStor at `https://app-minio-openlat.cloud.sdu.dk`; the `mc` alias used throughout is `ucloud`.

| Access path | Who | Policy | What it allows |
| --- | --- | --- | --- |
| IAM-ILDG login (OIDC, STS) | Any IAM-ILDG user | `ildg_download` | Download objects tagged `ildg_download=true`; everything else is denied |
| Local user, group `openlat_read_access_users` | Group members | `openlat_read_access` | List and read all objects in `openlat`, read tags |
| Local user, group `openlat_full_access_users` | Group members | `openlat_full_access` | Read, write, delete and tag objects; no bucket-level changes |
| Delegated user manager | `carla` | `openlat_manager` | Create users and add them to existing groups; cannot change policies |
| Administrator | `ada` | Administrator rights (not described here) | Manages users, groups and policies |

## Using openlat

There are two ways in, and which one applies depends on how your account was created.

### IAM-ILDG login: download tagged files

1. Obtain an OIDC ID token from IAM-ILDG using the client the server trusts (client ID `d945d43c-adf6-40c3-bfa0-c4c90b5e435b`). A token issued to any other client is rejected with "`azp` must match configured OpenID Client ID". The tokens seen so far were valid for 10 minutes.
2. Exchange the token for temporary credentials with `AssumeRoleWithWebIdentity` at `https://app-minio-openlat.cloud.sdu.dk/`, using RoleArn `arn:minio:iam:::role/6fjOfWNrqjJUCfLsZaCiAD3J8k0` and `DurationSeconds=3600`.
3. Use the returned access key, secret key and session token with any S3 client, or run the helper script:

```bash
ID_TOKEN=<token> ./minio_sts_curl_download.sh openlat path/to/file.dat
```

Only objects whose tag `ildg_download` equals `true` can be downloaded. A file tagged `false`, or with no tag, is denied: the script prints `Download failed: HTTP <code>` and exits without writing a file.

### Local user: use mc

```bash
mc alias set ucloud https://app-minio-openlat.cloud.sdu.dk <USERNAME> '<PASSWORD>'
mc ls ucloud/openlat/
mc cp ucloud/openlat/path/file.dat .
```

Members of `openlat_full_access_users` can also upload, delete and tag:

```bash
mc cp ./file.dat ucloud/openlat/path/file.dat
mc rm ucloud/openlat/path/file.dat
```

Members of `openlat_read_access_users` can list and download everything in the bucket but cannot change anything.

## Publishing data

A file becomes downloadable for IAM-ILDG users when it carries the tag `ildg_download=true`; removing the tag withdraws it. Tagging is therefore the publication switch.

```bash
mc tag set ucloud/openlat/path/file.dat "ildg_download=true"
mc tag set --recursive ucloud/openlat/path/ "ildg_download=true"   # confirm the flag with: mc tag set --help
mc cp --tags "ildg_download=true" ./file.dat ucloud/openlat/path/
mc tag list ucloud/openlat/path/file.dat
mc tag remove ucloud/openlat/path/file.dat
```

- Tags belong to objects, not to directories. `--recursive` tags the files that exist at that moment; files added later stay untagged until tagged.
- The value must be exactly `true`. Testing confirmed that `true` downloads, while `false` and no tag are both denied.
- Uploading a new copy of an object without `--tags` replaces its tags, so re-tag after overwriting.
- Who can tag: members of `openlat_full_access_users` and users with `openlat_full_access` attached directly. The read group and IAM-ILDG logins cannot tag.

## Administrator setup

The state below is the backup of 2026-10-02 plus the manager user carla, added afterwards. Administer the server with an administrator alias:

```bash
mc alias set ucloud https://app-minio-openlat.cloud.sdu.dk <ADMIN_KEY> <ADMIN_SECRET>
mc admin policy entities ucloud     # who holds which policy
```

### Local users

| User | Policies | Group memberships |
| --- | --- | --- |
| `ada` | `openlat_full_access` (direct); administrator rights not described here | none |
| `bruno` | none directly | `openlat_read_access_users` |
| `carla` | `openlat_manager` (direct) | `openlat_full_access_users` |

### Groups

| Group | Policy | Members | Status |
| --- | --- | --- | --- |
| `openlat_read_access_users` | `openlat_read_access` | `bruno` | enabled |
| `openlat_full_access_users` | `openlat_full_access` | `carla` | enabled |

### OpenID provider (IAM-ILDG)

One unnamed (default) OpenID configuration is active. Every IAM-ILDG login receives only its `role_policy`.

| Setting | Value |
| --- | --- |
| Display name | `IAM-ILDG` |
| Config URL | `https://iam-ildg.cloud.cnaf.infn.it/.well-known/openid-configuration` |
| Client ID | `d945d43c-adf6-40c3-bfa0-c4c90b5e435b` |
| Role policy | `ildg_download` |
| Claim name | `policy` (not used while `role_policy` is set) |
| Scopes | `openid,profile,email` |
| Dynamic redirect URI | off |
| RoleARN | `arn:minio:iam:::role/6fjOfWNrqjJUCfLsZaCiAD3J8k0` |

The client secret is not stored in the backup; keep it in the password manager. If the Client ID is changed, tokens issued to any other client stop working.

## Policies

Four custom policies control the bucket and user delegation. The authoritative copies are the files in `policies/` of the latest backup folder; the JSON below shows their intended content, and it matches the policy files exported on 2026-10-02.

| Policy | Purpose | Attached to |
| --- | --- | --- |
| `ildg_download` | Download objects tagged `ildg_download=true`; no listing | OpenID role policy (all IAM-ILDG logins) |
| `openlat_read_access` | List and read every object, read tags | Group `openlat_read_access_users` |
| `openlat_full_access` | Read, write, delete and tag objects; no bucket-level changes | Group `openlat_full_access_users` and user `ada` |
| `openlat_manager` | Create users and add them to groups; no policy changes | User `carla` |

Permissions from all attached policies add up, so a user who also holds `openlat_full_access` or `readwrite` can download untagged files regardless of `ildg_download`.

### openlat\_full\_access

Bucket-level actions such as deleting the bucket, changing the bucket policy or lifecycle rules are deliberately left out.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::openlat"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:GetObjectTagging", "s3:PutObjectTagging", "s3:DeleteObjectTagging",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::openlat/*"]
    }
  ]
}
```

### openlat\_read\_access

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::openlat"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectTagging"],
      "Resource": ["arn:aws:s3:::openlat/*"]
    }
  ]
}
```

### ildg\_download

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": [
        "arn:aws:s3:::openlat",
        "arn:aws:s3:::openlat/*"
      ],
      "Condition": {
        "StringEquals": {
          "s3:ExistingObjectTag/ildg_download": [
            "true"
          ]
        }
      }
    }
  ]
}
```

The policy has no list permission, so IAM-ILDG users cannot browse the bucket and need the exact object path. Listing the bucket requires `openlat_read_access` or `openlat_full_access`.

### openlat\_manager

This policy lets a delegated manager create users and add them to existing groups. It grants no right to create, delete, attach or detach policies.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "admin:CreateUser", "admin:ListUsers", "admin:GetUser",
        "admin:EnableUser", "admin:DisableUser",
        "admin:AddUserToGroup", "admin:GetGroup", "admin:ListGroups"
      ]
    }
  ]
}
```

Group membership hands out each group's rights, so the holder can also place users in `openlat_full_access_users`; see the security notes.

## Routine administration

Group membership decides a local user's access, so add users to the group that matches their role and avoid attaching policies to users directly.

```bash
# new read-only user
mc admin user add ucloud <name> '<password>'
mc admin group add ucloud openlat_read_access_users <name>

# new user with full access
mc admin user add ucloud <name> '<password>'
mc admin group add ucloud openlat_full_access_users <name>

# inspect
mc admin user info ucloud <name>
mc admin policy entities ucloud

# disable or enable a user
mc admin user disable ucloud <name>
mc admin user enable ucloud <name>

# reset a password (overwrites the secret; check policies and groups afterwards)
mc admin user add ucloud <name> '<new password>'
```

To change a policy, export it, edit it and create it again under the same name, which overwrites the old version for everyone it is attached to:

```bash
mc admin policy info ucloud <policy> --json | jq '.policyInfo.Policy' > <policy>.json
# edit <policy>.json
mc admin policy create ucloud <policy> ./<policy>.json
```

A user who holds `openlat_manager` onboards people in two steps: create the user, then add it to the group that matches the intended access. The manager cannot attach policies, so group membership is the only way to give rights. The manager's own credentials go into a separate alias (called `mgr` here):

```bash
mc alias set mgr https://app-minio-openlat.cloud.sdu.dk <MANAGER_USER> '<MANAGER_PASSWORD>'

# read-only user: list and download everything in openlat
mc admin user add mgr <name> '<password>'
mc admin group add mgr openlat_read_access_users <name>

# full-access user: read, write, delete and tag
mc admin user add mgr <name> '<password>'
mc admin group add mgr openlat_full_access_users <name>

# check the result
mc admin user info mgr <name>
mc admin group info mgr openlat_read_access_users
mc admin group info mgr openlat_full_access_users
```

- Choose one group per person. Permissions add up, so full access already includes reading.
- Use `openlat_full_access_users` only for people who may publish or delete data, because tagging a file publishes it.
- Send the password to the new user through a secure channel; it cannot be read back afterwards.
- Attaching a policy, creating a policy or deleting a user is denied for this role; ask an administrator for those.

Two scripts support the routine work, and both only read from the server:

- `ucloud_policy_audit.sh [alias] [bucket]` collects policies, mappings, OpenID settings, bucket access rules and tag tests into `audit_<alias>_<timestamp>/ALL.txt`.
- `ucloud_iam_backup.sh [alias]` writes the backup described in the restore procedure. Run it after every change to users, groups or policies, and store the encrypted result off this machine.

## Security notes and open items

Publishing data and handing out access are limited to a few roles, and the notes below keep it that way.

- **Critical: the RoleARN.** IAM-ILDG users have no account on the server. To get temporary credentials they send their IAM-ILDG token together with a RoleARN (currently `arn:minio:iam:::role/6fjOfWNrqjJUCfLsZaCiAD3J8k0`), and the server uses that identifier to look up which policy to apply (`ildg_download`). The server generates the RoleARN itself for the OpenID configuration; it cannot be chosen. The documentation does not say whether an upgrade alone changes it, and it has already changed once on this server. Every script and client has the value written into it, so if it changes, IAM-ILDG downloads fail until the new value is distributed. After any upgrade, restore or change to the OpenID settings, run `mc idp openid ls ucloud`, compare the RoleARN with the one above, and update the clients if it differs.
- **Critical: the client ID.** The OpenID configuration contains the client ID of the application registered at IAM-ILDG (`d945d43c-adf6-40c3-bfa0-c4c90b5e435b`). Every IAM-ILDG token names the client it was issued to, and the server accepts a token only if that name matches its configuration; otherwise the request fails with "`azp` must match configured OpenID Client ID". This happened during testing, when a token came from a different client. The client ID on the server must therefore always equal the client that users obtain their tokens from, so do not change it without agreeing with the IAM-ILDG operators. The server also allows a client ID in only one OpenID configuration, so a second test configuration cannot reuse it.
- **Administrator access.** Keep the root credentials stored safely by the people who run the deployment, so access can be recovered if the administrator's key is lost.
- **Tagging is publication.** Anyone with `openlat_full_access` can publish or withdraw files. Keep that group small, and do not attach `readwrite`, `readonly` or `openlat_full_access` to users who should be limited to tagged downloads.
- **Bucket access.** The bucket is private (`mc anonymous get ucloud/openlat` reports `private`). Re-check this after any bucket-level change.
- **Delegated user management.** `openlat_manager` lets its holder create users and add them to groups, but not change policies. Group membership hands out each group's rights, including those of `openlat_full_access_users`, and creating a user under an existing name may reset that user's secret (not tested here). Give it only to trusted people and test it with a throwaway user first. It is attached directly to `carla`, who is also a member of `openlat_full_access_users`.
- **Credentials hygiene.** Rotate any key or secret that was pasted into chats, tickets or logs, and keep ID tokens and temporary credentials out of script output.
