# Embeddings

`POST /v1/embeddings` turns one or more protein sequences into **ESMC protein
language-model embeddings** — numeric vectors you can feed to a classifier,
clustering, similarity search or any downstream model. It returns a **job** to
poll (see [Jobs](jobs.md)); there is no structure prediction and no MSA.

## Two kinds of vector

For every sequence you get both:

- **Per-residue** — one vector per amino acid, shape `[length, d_model]`. Use
  it for residue-level tasks (contact/site prediction, per-position features).
  The `<cls>`/`<eos>` boundary tokens are stripped, so row *i* is residue *i*.
- **Pooled** — a single fixed-size vector per sequence, shape `[d_model]`,
  obtained by combining the per-residue vectors (see `pool` below). Use it when
  you want one vector per protein (similarity, clustering, a sequence-level
  classifier).

`d_model` depends on the model (e.g. 960 for `esmc-300m`) and is reported in the
results.

## Input

Provide **one** of these, exactly like [Predictions](predictions.md):

### 1. `sequence`: a single chain (simplest)

```bash
curl -s -X POST https://api.japanfold.com/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"esmc-600m","sequence":"MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ"}'
```

### 2. `sequences`: a list, to embed many in one job

Each item is a bare string, or an object `{"sequence": "...", "id": "..."}`:

```bash
curl -s -X POST https://api.japanfold.com/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"esmc-600m",
    "sequences":[
      {"id":"a","sequence":"MKTAYIAKQRQISFVKSHFSRQLEE"},
      {"id":"b","sequence":"GIVEQCCTSICSLYQLENYCN"}
    ]
  }'
```

### 3. `input`: one FASTA string

```bash
curl -s -X POST https://api.japanfold.com/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"esmc-600m","input":">a\nMKTAYIAKQRQISFVKSHFSRQLEE\n>b\nGIVEQCCTSICSLYQLENYCN"}'
```

## Models

Set `model` (default `esmc-600m`). All three are ESMC; larger is a stronger
representation at more compute per sequence. See
[Models & limits](models-and-limits.md).

| `id` | Name | Use it for |
|---|---|---|
| `esmc-300m` | ESMC 300M | Quickest embeddings, still a strong general-purpose representation. |
| `esmc-600m` | ESMC 600M | The balanced default. |
| `esmc-6b` | ESMC 6B | The strongest representation, at higher compute cost. |

## Parameters

Pass a `params` object.

| Key | Type | Default | Notes |
|---|---|---|---|
| `pool` | enum | `mean` | How per-residue vectors become the pooled vector: `mean`, `max`, or `cls` (the `<cls>` token). |
| `format` | enum | `npz` | `npz`: per-residue + pooled, one file per sequence. `parquet`: pooled vectors only, one table. |
| `fast` | bool | `false` | Higher throughput, may be slightly less precise. |

```bash
curl -s -X POST https://api.japanfold.com/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"esmc-600m","sequence":"MKTAYIAK...","params":{"pool":"mean","format":"npz"}}'
```

## Results

Poll `GET /v1/jobs/{id}` and, once `results_ready` is true, read
`GET /v1/jobs/{id}/results`. For an embed job the body carries `kind: "embed"`,
the `model`, `pool`, `format`, `d_model`, a `sequences` list
(`{id, length, file}` per input), and an `artifacts` list of download URLs.

- **`npz`** (default): one `<id>.npz` per sequence with arrays `per_residue`
  `[length, d_model]`, `pooled` `[d_model]`, and `sequence`.
- **`parquet`**: a single `embeddings.parquet` — the pooled matrix, one row per
  sequence (per-residue vectors are ragged, so they are not in the table; use
  `npz` for those).

Download individual files from their artifact `url`, or the whole set from
`GET /v1/jobs/{id}/archive`.

## End to end (Python)

```python
import io, time, httpx, numpy as np

BASE = "https://api.japanfold.com"
job = httpx.post(f"{BASE}/v1/embeddings",
                 json={"model": "esmc-600m",
                       "sequence": "MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ"}).json()
while job["status"] not in ("succeeded", "failed", "canceled"):
    time.sleep(3)
    job = httpx.get(f"{BASE}/v1/jobs/{job['id']}").json()

res = httpx.get(f"{BASE}/v1/jobs/{job['id']}/results").json()
url = BASE + res["artifacts"][0]["url"]
data = np.load(io.BytesIO(httpx.get(url).content))
print(data["per_residue"].shape, data["pooled"].shape)  # (L, d_model) (d_model,)
```

## From your agent (the skill)

With the [JapanFold skill](skill.md) installed, just ask:

> *"Embed these sequences with ESMC-600M and save the pooled vectors."*

## Waiting inline, retrying safely

Embed jobs accept the same `Prefer: wait[=seconds]` header (block until done, up
to 60s) and `Idempotency-Key` (a retried submit returns the original job) as
predictions — see [Predictions](predictions.md#waiting-inline-the-prefer-wait-header).

## Limits

Free public demo: at most **50 sequences per submission** and **2000 residues
per sequence** (embeddings run the language model only, so this is higher than
the folding size cap). Over a cap → `400`; at capacity → `429`. See
[Models & limits](models-and-limits.md) and [Errors](errors.md).
