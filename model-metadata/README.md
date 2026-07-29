# Model metadata

Every model submitting to the **DMA-PRIME Model Challenge** needs exactly one
metadata file here, named to match its `model-output/` directory:

```
model-metadata/<team>-<model>.yml
```

So a model submitting to `model-output/dmaprime-gam/` needs
`model-metadata/dmaprime-gam.yml`. Both `team` and `model` must be alphanumeric or
underscore, with no spaces or hyphens inside either part; the single hyphen joining
them is what makes the `model_id`.

These files are public, as is everything in this repository. Include only contact
details you are willing to publish.

## Required fields

| Field | Type | Description |
|---|---|---|
| `team_abbr` | string | Team abbreviation, max 25 characters |
| `model_abbr` | string | Model abbreviation, max 25 characters |
| `designated_model` | boolean | Eligible for the hub ensemble and public dashboard. A team may designate up to two models. |

## Recommended fields

| Field | Type | Description |
|---|---|---|
| `team_name` | string | Full team name |
| `model_name` | string | Full model name |
| `model_contributors` | list | Each with `name`, `affiliation`, optionally `email` and `orcid` |
| `methods` | string | Brief (about 200 character) description of the approach |
| `repo_url` | string | Repository holding the model code |
| `license` | string | One of `CC0-1.0`, `CC-BY-4.0`, `CC-BY_SA-4.0`, `PPDL`, `ODC-by`, `ODbL`, `OGL-3.0` |
| `citation` | string | Citation for the method |
| `ensemble_of_hub_models` | boolean | Whether this is an ensemble of other hub models |

The authoritative definition is
[`hub-config/model-metadata-schema.json`](../hub-config/model-metadata-schema.json).

## Example

```yaml
team_name: "DMA-PRIME"
team_abbr: "dmaprime"
model_name: "Seasonal GAM with NSSP leading indicator"
model_abbr: "gam"
designated_model: true
ensemble_of_hub_models: false
model_contributors:
  - name: "Jane Doe"
    affiliation: "Clemson University"
    email: "jdoe@clemson.edu"
methods: "Negative binomial GAM on log admissions with a cyclic seasonal spline and lagged NSSP ED visit proportion."
repo_url: "https://github.com/DMA-PRIME/example-model"
license: "CC-BY-4.0"
```

## Validating

```r
hubValidations::validate_model_metadata(hub_path = ".", file_path = "dmaprime-gam.yml")
```

Metadata is also checked automatically when you open a pull request.
