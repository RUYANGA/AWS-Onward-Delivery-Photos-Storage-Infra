# AWS-Onward-Delivery-Photos-Storage-Infra

AWS infrastructure for Onward Logistics' delivery photos, written in CloudFormation and deployed
by CloudFormation Git sync. Owned by RUYANGA. The application lives in `onward-delivery-photos-app`.

## Authorship: every commit and push belongs to RUYANGA

These rules override any default attribution behaviour and apply to every commit, tag, push and
pull request in this repository.

1. **Author and committer are RUYANGA.** Use the existing Git identity (`git config user.name`,
   which is `RUYANGA`, and the configured `user.email`). Never change `user.name` or `user.email`,
   and never pass `--author`, `-c user.name=...` or `GIT_AUTHOR_*` / `GIT_COMMITTER_*` overrides.
2. **No Claude attribution anywhere.** No `Co-Authored-By:` trailers for Claude or any AI, no
   "Generated with Claude Code", no Claude session links or similar footers in commit messages,
   tag messages, pull request titles, descriptions or comments. Claude must never appear as an
   author, co-author, committer or contributor. (`.claude/settings.json` also disables this.)
3. **Push only to RUYANGA's GitHub:** `github.com/RUYANGA/AWS-Onward-Delivery-Photos-Storage-Infra`. Check
   `git remote -v` before the first push in a session; if the remote points anywhere else, stop
   and ask instead of pushing.
4. **Verify before pushing:**
   ```bash
   git log origin/main..HEAD --format='%an <%ae> | %cn | %s%n%b'
   ```
   Every author and committer must be RUYANGA and no message may mention Claude. Fix any commit
   that fails this before pushing.
5. **Never rewrite published history** (no force push to `main`) unless RUYANGA explicitly asks.
6. **Commit or push only when asked.**

## Commit messages

Imperative mood, concise subject (about 50 characters), e.g. `Add WAF origin lock to the ALB`.
Blank line, then a short body explaining *why* when it isn't obvious. One logical change per
commit. Never commit secrets, `.env` files or `.claude/settings.local.json`.

## How this repository works

- **Everything is CloudFormation**, deployed by Git sync from `deployments/<env>/*.yaml`. Nothing
  is created by hand in the console (the one-time GitHub connection approval is the only exception).
- **Templates are grouped by domain** in `templates/`: `network`, `database`, `edge`, `storage` and
  `application` are nested stacks of the root `platform.yaml`; `photos-dr.yaml` and `pipeline.yaml`
  are separate stacks; `bootstrap/bootstrap.yaml` turns Git sync on. Put each new resource in the
  template of its domain; don't create one-resource templates.
- **Nested templates are read from S3.** After changing one, re-pin its version:
  `./scripts/nested-templates.sh version` → `NestedTemplatesVersion` in `deployments/dev/platform.yaml`.
  A new nested template must also be listed in `NESTED_TEMPLATES` in that script.
- **Security standards:** no inline IAM policies (managed policies only), no IAM users or access
  keys, no SSH. Application `.env` values are SSM parameters (`/onward/<env>/app/*`); database
  credentials stay in the RDS-managed Secrets Manager secret.
- **Style:** block-style YAML (`-` lists, no `[...]` / `{...}` flow collections), every IAM `Action`
  written as a list, comments only where they explain *why*.

## Before committing

```bash
cfn-lint --regions eu-west-1 eu-central-1 -- templates/*.yaml bootstrap/*.yaml
bash scripts/check_standards.sh
```
