# terraform-aws-backup

Scenario 4 of the skills assessment. Scenarios 1 to 3 are answered in `answers.md`.

The module implements the validated backup design on AWS Backup: a plan with configurable frequency, retention and encryption, tag-based selection (`ToBackup=true` and `Owner`), cross-region copy from Frankfurt to Ireland, cross-account copy into the backup account (each copy with its own retention and KMS key), and Vault Lock (WORM) on the three vaults.

## How to run

Terraform >= 1.3, and three AWS provider configurations in the root: default (prod, Frankfurt), `dr` (prod, Ireland), `central` (backup account).

```hcl
module "backup_policy" {
  source = "./terraform-aws-backup"

  providers = {
    aws         = aws
    aws.dr      = aws.dr
    aws.central = aws.central
  }

  owner = "team-mailbox@example.com"
}
```

Then `terraform init` and `terraform apply`. With the defaults that gives daily backups at 03:00, 35 days retention, a 35-day DR copy, a 90-day central copy and Vault Lock enabled. Frequency, retention, cold storage and lock settings are all variables, see `variables.tf`.


# Answers


Scenarios 1 to 3 are answered below. Scenario 4 is delivered as a Terraform module.

---

## Scenario 1: Encryption management, key rotation on AWS

### 1. Main challenges and impacts

The defining constraint is that our keys are EXTERNAL origin (BYOK), and KMS automatic rotation does not support imported key material. Rotation is therefore our process end to end, on our cadence, with our evidence trail for the regulator.

Every rotation implies a full HSM ceremony per key: generate new material on-prem, wrap it, import it. With one key per environment and service (dev/int/prod x s3/rds/ddb, and growing) this only works as an automated, recurring runbook. Not as a one-off manual task.

Rotating a key is also not the same as re-encrypting data. New key material only applies to new encrypt operations, and everything already stored stays protected by the old material. If the regulator reads "rotation" as "re-encrypt existing data", that is a separate and much heavier project. For S3 with SSE-KMS, objects keep the key material they were written with, so re-encryption means copying objects in place with S3 Batch Operations. For RDS, the KMS key of an encrypted instance cannot be changed in place: it takes snapshot, copy snapshot with the new key, restore, cutover, with a downtime window. DynamoDB is the cheap one, since the CMK only wraps the table key and switching it is a metadata re-wrap with no data rewrite.

Imported key material carries its own lifecycle risk. If any imported material expires or is deleted, the KMS key becomes unusable and old ciphertexts unreadable. And rotation multiplies the material versions we have to custody, both in KMS (expiry dates) and on-prem.

On the consumer side, aliases only apply on encrypt (decrypt resolves the key from the ciphertext), so our alias-based setup absorbs most of the change. The residual risk is anything pinned to a key ID or ARN in IaC, resource configs or key policies, plus cross-account grants that would need to be replicated exactly if we rotate by creating new keys.

### 2. Steps to apply rotation (high level)

Since June 2025 KMS supports on-demand rotation of symmetric keys with imported material, keeping the same key ID, ARN and alias, so that is the path I would take:

1. Inventory: list all EXTERNAL keys, their aliases, key policies and grants, and which resources use each one (Config plus CloudTrail usage), so we know the blast radius per key.
2. Generate the new key material on the on-prem HSM.
3. For each key, request the wrapping public key and import token from KMS and wrap the new material inside the HSM.
4. ImportKeyMaterial as new rotation material and trigger RotateKeyOnDemand (immediate or scheduled). Key ARN and alias do not change, and old material stays available for decrypt, so there is zero impact on running workloads.
5. Roll out in waves using the environment segregation we already have: dev first, validate encrypt and decrypt on each service, then int, then prod.
6. Housekeeping and evidence: ListKeyRotations is the audit record for the regulator. Track the expiry of every material version, and never delete or let old material expire while ciphertexts still depend on it.
7. Only if required, re-encrypt stored data per service (S3 batch copy, RDS snapshot-copy-restore, DynamoDB key switch) after the rotation.

For anything the on-demand path does not cover, asymmetric keys for example: create a new EXTERNAL key with identical policy, import the new material, re-point the alias, and keep the old key enabled for decrypt only. Disable it once traffic and retention allow. Never schedule deletion while data depends on it.

### 3. Monitoring non-compliant resources with an AWS managed service

AWS Config, aggregated into the security account.

The managed rule cmk-backing-key-rotation-enabled only checks automatic rotation, which BYOK keys cannot use, so it does not fit here. Instead, a custom Config rule (Lambda-backed) evaluates each KMS key: query ListKeyRotations / GetKeyRotationStatus and mark NON_COMPLIANT when the last rotation is older than the policy SLA or never happened.

A second custom rule covers the resource side. It runs over rds, dynamodb and s3 resources, resolves each resource's KmsKeyId, and checks that it belongs to the current compliant key set for its environment and service. This catches resources still pointing at retired keys or at the wrong key.

Package both as a conformance pack deployed to all accounts, aggregate with a Config aggregator in the security account, and surface findings in Security Hub. EventBridge on non-compliance events feeds alerts and ticketing. That gives the "at any given time" view the requirement asks for: Config keeps evaluating continuously and Security Hub is the single pane.

### 4. Securing key material in transport from HSM to KMS

Plaintext key material never leaves the HSM boundary. We use the KMS import flow: download the KMS public wrapping key and import token (single use, 24h validity), perform the wrapping inside the HSM, and only the wrapped blob travels. Use the strongest wrapping spec supported, RSA_AES_KEY_WRAP_SHA_256 (hybrid AES wrap under RSA-OAEP), instead of plain RSAES-OAEP.

The ImportKeyMaterial call itself goes over TLS, and I would force it through a private path: a KMS interface VPC endpoint reached via Direct Connect or VPN from the datacenter, so the wrapped material never transits the public internet.

The ceremony gets its own controls. A dedicated import role with least privilege (kms:GetParametersForImport and kms:ImportKeyMaterial on the specific key only), MFA and four-eyes on execution, CloudTrail alerting on the import APIs, and the wrapped blob wiped right after a successful import.

---

## Scenario 2: APIs-as-a-Product, public and private APIs

### 1. Weaknesses in the current architecture

The biggest one: the regional API Gateway endpoints are public, so CloudFront, the global WAF and Shield can be bypassed entirely by calling execute-api directly (the attacker arrow in the diagram). All the edge protection is effectively optional for an attacker.

Internal application-to-application calls leave our network and hairpin over the internet through CloudFront to reach services that have no external consumer. Extra latency, egress cost, availability coupled to the edge, and internal traffic exposed on a public path for no reason.

"Public by design" also means the attack surface includes every API, including the ones nobody external uses. A vulnerability in any team's API is internet-facing by default. And one shared domain with one shared edge config is a shared blast radius: a WAF rule mistake, throttling limits, cache behavior or a DDoS focused on one product path affects everyone.

The Lambda authorizer sits in the critical path of every request. That means added latency and cold starts, and a bug or outage in it takes the whole API surface down. Authorizer result caching across methods is also a classic source of subtle auth bugs.

Two smaller points. Two WAF layers (global plus regional) with no clear ownership tends to rule drift and duplicated maintenance. And nothing in the design covers partner-grade controls: no mTLS option, no visible per-consumer usage plans or quotas.

### 2. Target architecture (internal goes private, mixed goes both, minimal impact)

The principle is to touch only the exposure layer. Backends (Lambdas and the internal ALB plus Fargate) stay exactly as they are.

Internal-only APIs get redeployed as PRIVATE API Gateway endpoints. Consumers reach them through execute-api interface VPC endpoints from our VPCs, and from the corporate network via Direct Connect or VPN. The API resource policy denies everything except the approved aws:sourceVpce, keeping the least-privilege posture. A private hosted zone plus private custom domain names for API Gateway (supported for private APIs since late 2024, shareable cross-account with RAM) gives internal consumers stable, clean hostnames.

Mixed internal-plus-external APIs need two endpoints, because an API Gateway endpoint is either public or private, not both. The existing public path through CloudFront, WAF and the regional API Gateway stays for customers and brokers, and a private endpoint is added in front of the same backend for internal consumers. Split-horizon DNS makes it transparent: api.allianz-trade.com resolves to CloudFront on the internet and, inside our network via the private hosted zone, to the VPC endpoint. Internal callers change nothing and their traffic never leaves the network.

```
external clients ── CloudFront + WAF/Shield ── regional API GW (public, mixed APIs only) ─┐
                                                                                          ├─ same Lambdas / ALB+Fargate
corp network / VPCs ── DX/VPN ── execute-api VPC endpoint ── private API GW ──────────────┘
        (split-horizon DNS: same hostname resolves to the right entry point)
```

Why this is low impact: no backend changes, no client code changes internally (DNS does the switch), and the external path is untouched. The work is provisioning private endpoints, VPC endpoints, resource policies and the private zone.

### 3. CloudFront path-based routing to multiple API Gateways

One distribution, one origin per regional API Gateway (its execute-api or regional custom domain), and one cache behavior per path pattern: /policies/* to APIGW-A, /claims/* to APIGW-B, default behavior to the core API.

The origin path setting injects the stage (e.g. /prod). When the target API does not expect the routing prefix, a CloudFront Function on the behavior strips it.

For APIs specifically, use the origin request policy AllViewerExceptHostHeader, because API Gateway must receive its own Host header. Forward Authorization explicitly, and keep caching disabled or very selective.

### 4. Protecting regional endpoints from CloudFront/WAF bypass

Make the origin verify the request really came through our edge, two layers deep.

First, a secret origin header. CloudFront adds a custom origin header (e.g. X-Origin-Verify) whose value lives in Secrets Manager and is rotated by a Lambda. A regional WAFv2 rule on each API Gateway blocks any request that does not carry the current value. This is the AWS-documented pattern for exactly this problem.

Second, a network allow-list. Restrict the regional side to CloudFront's origin-facing IP ranges, published in ip-ranges.json. The AmazonIpSpaceChanged SNS topic triggers a Lambda that keeps a regional WAF IPSet (or the aws:SourceIp condition in the API resource policy) in sync automatically.

Structurally, though, the long-term fix is to stop having public regional endpoints where we do not need them. The private API work from question 2 already removes the bypass class for internal APIs, and for the ALB-backed services CloudFront VPC origins allow making the origin fully private.

---

## Scenario 3: Resilience and monitoring, GitLab service

### 1. Weaknesses of the current architecture

The whole application tier is a single EC2 instance in a single AZ. Instance failure, EBS volume failure or an AZ event means a full outage. Only the database layer is HA.

EBS is AZ-bound, so the repos and artifacts volume has no standby copy. RPO is whatever the last snapshot was (no snapshot policy is shown) and RTO is a manual rebuild.

Everything is colocated on the box: Rails/Puma, Sidekiq, Redis, Gitaly. That means vertical scaling only, resource contention (CI load can starve the web UI), and every upgrade or reboot is planned downtime. Nothing sits in front of the instance, no load balancer, no health checks, no auto-recovery, so clients are pinned to it.

The backup and restore path is undefined: gitlab-backup vs snapshots, and no evidence restores are ever tested.

### 2. Target architecture

Phased, and GitLab-aware. Git repositories on NFS/EFS is explicitly discouraged by GitLab, so the design cannot be "just put the data on EFS".

1. Shrink the state on the instance. GitLab natively offloads artifacts, LFS, uploads, packages, container registry and CI caches to S3. Redis moves to ElastiCache, and the database is already RDS Multi-AZ. After this, the only real state left on the box is Gitaly (the git repos).
2. Automated recovery (pilot light). The instance runs in an ASG min=1/max=1 spanning two or more AZs behind an ALB (plus an NLB for SSH), built from a golden AMI, with the data volume recreated from frequent EBS snapshots (AWS Backup/DLM, fast snapshot restore enabled in both AZs). Failure of the instance or the AZ becomes an automatic re-provision in minutes, and RPO equals the snapshot interval.
3. Real HA, if the RTO/RPO targets demand it. Split the tiers: stateless web and Sidekiq nodes in a multi-AZ ASG behind the ALB, and repo storage on a Gitaly Cluster (Praefect plus 3 Gitaly nodes across AZs) with replicated git data. This is the reference way to make GitLab's git storage highly available on AWS.

```
users ── Route53 ── ALB (https) / NLB (ssh) ── ASG: GitLab web+sidekiq (multi-AZ)
                                                  │            │
                                     Gitaly (EBS + snapshots,  ├─ RDS Multi-AZ
                                     or Gitaly Cluster for HA) ├─ ElastiCache Redis
                                                               └─ S3 (artifacts, LFS, registry, backups)
```

### 3. Monitoring practices

Outside-in first. A CloudWatch Synthetics canary runs a real user flow (login page, API call, git ls-remote over HTTPS) every few minutes, plus ALB target health and Route 53 health checks against GitLab's own /-/health, /-/readiness and /-/liveness endpoints. This catches "users cannot work" regardless of the internal cause.

GitLab exports Prometheus metrics natively, so scrape them into Amazon Managed Prometheus with Grafana on top, or via the CloudWatch agent. The leading indicators worth alerting on: Puma/Workhorse saturation and request queueing, Sidekiq queue depth and latency, Gitaly RPC latency and error rate, Redis and DB connection pool saturation, and CI job queue time.

On the infrastructure side, the CloudWatch agent covers memory and disk. Data-volume fill-up is the classic GitLab outage, so alarm at 75% and 85% on the repo and artifact volume. Also watch EBS IOPS and throughput, EC2 status checks, and RDS CPU, connections and storage.

Logs (production_json.log, Gitaly, nginx) go to CloudWatch Logs with metric filters on 5xx and error spikes. Composite alarms feed SNS to on-call and chat. What pages us is symptoms (canary failing, error rate, latency) plus a few leading indicators, not raw noise.

### 4. Automating the GitLab runbook

Configuration becomes code: gitlab.rb and OS config via Ansible (or a golden AMI pipeline with EC2 Image Builder/Packer), enforced with SSM State Manager. Nobody hand-edits the server.

Operational runbooks become SSM Automation documents. The upgrade one, for example: pre-checks (supported upgrade path for the target version, gitlab-backup to S3, EBS and RDS snapshots), enable maintenance mode and drain, step-wise package upgrade, post-checks (/-/health green, background migrations finished), and an automatic rollback path that restores the snapshots if post-checks fail. Same pattern for restore, node recycle and certificate renewal.

Execution goes through SSM Maintenance Windows with approval steps and a Change Calendar, triggered from a pipeline or EventBridge. One caveat I would keep: recovery automation stays out-of-band from GitLab CI itself, because we cannot use the toolchain to heal the toolchain.

And backups are only real if restores are. A scheduled job restores the latest backup into a scratch environment and verifies it, automatically.

---

## Scenario 4: Backup policy with AWS Backup

Delivered as a Terraform module (see attachment / repository). It implements the validated design: a backup plan with configurable frequency, retention and encryption, tag-based resource selection (ToBackup=true and Owner), cross-region copy from Frankfurt to Ireland and cross-account copy to the backup account (each copy with its own retention and KMS key), and Vault Lock on all three vaults for WORM protection. Details and usage are in the module README.
