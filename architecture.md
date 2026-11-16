# Books to Music: AWS architecture

Diagram: [architecture.drawio](architecture.drawio). Everything shown is defined in `terraform/` (region `us-east-2`) except the pre-existing `discogs-pat` secret and the external Discogs and Datadog services.

## Request flow

1. The browser calls the public **Lambda Function URL** over HTTPS (`authorization_type = NONE`). The handler checks the passphrase header against the `books-music/passphrase` secret.
2. `GET /` serves the page and `GET /api/books` reads `audible_listen_history.json` and `book_notes.json` from the private **S3** data bucket.
3. `POST /api/suggest` checks the **DynamoDB** cache (`books-music-cache`, TTL on `expires_at`). This table also holds the daily suggestion counter (limit 50).
4. On a cache miss, Lambda calls **Bedrock** Converse with the model chosen by the A/B switch: A is Nova 2 Lite, B is Nova Pro, both through `us.` cross-region inference profiles.
5. Each suggested album is checked against the **Discogs API** using the `discogs-pat` token from Secrets Manager. The results are cached in DynamoDB for 30 days.
6. Logs go to **CloudWatch Logs** (`/aws/lambda/books-music`, 14-day retention). The **Datadog extension** sends traces, logs, metrics and LLM Observability spans to Datadog.

## Deploy flow

- `deploy.sh` runs `terraform apply`. A `local-exec` step builds the arm64 image with `docker buildx` and pushes it to **ECR**. The image tag is a hash of `app/`, so any change to the source rebuilds the image and updates the Lambda.
- After the apply, `deploy.sh` sets the passphrase and the plaintext Datadog API key secret values. Doing this outside Terraform keeps them out of state.

## Services

| Service | Resource | Purpose |
|---|---|---|
| Lambda | `books-music` (image, arm64, 1024 MB, 60 s, reserved concurrency 2) | Web page and JSON API in one function |
| Lambda Function URL | auth `NONE` | Public endpoint, gated by the passphrase in the app |
| ECR | `books-music` (immutable tags, scan on push, keeps the last 5 images) | Container image |
| S3 | `books-music-data-*` (all public access blocked) | Listen history and book notes |
| DynamoDB | `books-music-cache` (on-demand, TTL) | Suggestion cache, Discogs cache, daily quota |
| Bedrock | Nova 2 Lite / Nova Pro inference profiles | Album suggestions |
| Secrets Manager | `books-music/passphrase`, `books-music/datadog-api-key`, `discogs-pat` | App secrets |
| IAM | `books-music-lambda` role | Least-privilege access to the resources above |
| CloudWatch Logs | `/aws/lambda/books-music` | Function logs |
| Datadog (external) | Dashboard "Books to Music" and 4 monitors (errors, passphrase guessing, daily limit, Discogs failures) | Observability |

## Key design decisions

- **One Lambda, no API Gateway.** A Function URL is enough for a single-user demo and needs no extra infrastructure.
- **Cost guardrails.** Reserved concurrency of 2, a daily limit on uncached Bedrock calls, and caching in DynamoDB.
- **Secrets stay out of Terraform state.** Terraform creates the secret containers and `deploy.sh` fills in the values.
- **The A/B model switch** lets the demo compare a lite model with a stronger one on the same prompt.
