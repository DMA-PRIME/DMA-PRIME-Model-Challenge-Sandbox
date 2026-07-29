# Model output

This folder holds one subdirectory per model, containing that model's submitted
forecasts, following the
[hubverse model output guidelines](https://docs.hubverse.io/en/latest/user-guide/model-output.html).

**Everything in this folder is public.** Every forecast submitted to the
**DMA-PRIME Model Challenge** is world readable, as is the score it receives.

## Contents

- [What is a forecast](#what-is-a-forecast)
- [Target data](#target-data)
- [Directory and file naming](#directory-and-file-naming)
- [File format](#file-format)
- [Column definitions](#column-definitions)
- [Example](#example)
- [Validation](#validation)
- [Deadline and late submissions](#deadline-and-late-submissions)
- [Evaluation](#evaluation)

## What is a forecast

Models make quantitative predictions about data that will be observed in the
future. These are **unconditional** predictions: they are not predictions for one
particular scenario, but should characterize uncertainty across all reasonable
futures. Every model makes some assumption about how current trends will change;
some teams pick a most likely scenario, others combine across several. Forecasts
submitted here are evaluated against observed data.

This is distinct from scenario projection efforts such as the
[Influenza Scenario Modeling Hub](https://fluscenariomodelinghub.org/), which
collect longer term projections under explicitly stated assumptions.

## Target data

Forecasts are scored against [`target-data/oracle-output.parquet`](../target-data/oracle-output.parquet),
built from CDC NHSN hospital admissions and CDC NSSP emergency department visit
data and refreshed every Wednesday. See
[`target-data/README.md`](../target-data/README.md) for schemas, sources, release
cadence, and known coverage gaps.

## Directory and file naming

Each model gets one subdirectory:

```
model-output/<team>-<model>/
```

`team` and `model` must each be under 15 characters and contain only alphanumerics
and underscores, with no spaces and no hyphens inside either part. The single
hyphen joining them forms the `model_id`, which must be unique in the hub.

Within it, one file per reference date:

```
model-output/<team>-<model>/<YYYY-MM-DD>-<team>-<model>.csv
```

where `YYYY-MM-DD` is the `reference_date`. `.parquet` is also accepted. The `team`
and `model` in the filename must match the directory name.

Each model also needs `model-metadata/<team>-<model>.yml`. See
[`model-metadata/README.md`](../model-metadata/README.md).

## File format

A comma separated file with exactly these columns, in any order. **No additional
columns are allowed.**

```
reference_date, target, horizon, location, target_end_date, output_type, output_type_id, value
```

Each row is one quantile of the predictive distribution for one combination of
target, location, and horizon.

You do not need to forecast every target, location, or horizon. Submit the rows you
have; validation checks that whatever you do submit is complete and well formed. If
you submit a given target/location/horizon at all, you must submit **all 23
quantiles** for it.

## Column definitions

### `reference_date`

ISO format date, `YYYY-MM-DD`. The Saturday ending the submission week. Must match
the date in the filename and must be one of the reference dates listed in
[`hub-config/tasks.json`](../hub-config/tasks.json).

### `target`

One of the six target IDs:

| Target | Meaning | Units |
|---|---|---|
| `wk inc covid hosp` | New confirmed COVID-19 hospital admissions | count |
| `wk inc flu hosp` | New confirmed influenza hospital admissions | count |
| `wk inc rsv hosp` | New confirmed RSV hospital admissions | count |
| `wk inc covid prop ed visits` | Proportion of ED visits due to COVID-19 | proportion |
| `wk inc flu prop ed visits` | Proportion of ED visits due to influenza | proportion |
| `wk inc rsv prop ed visits` | Proportion of ED visits due to RSV | proportion |

### `horizon`

Number of **weeks** between the `reference_date` and the `target_end_date`. One of
`0`, `1`, `2`, `3`.

Horizon 0 is a **nowcast** of the week you are currently in. Because the submission
deadline is Wednesday and NHSN's first release covering the reference week does not
appear until the following Wednesday, no data for the horizon 0 week have been
published at the time you submit.

### `target_end_date`

ISO format date, `YYYY-MM-DD`. The Saturday ending the predicted MMWR week:

```
target_end_date = reference_date + horizon * 7 days
```

### `location`

A location code from
[`auxiliary-data/locations.csv`](../auxiliary-data/locations.csv): `"US"` for
national, otherwise the 2 digit state FIPS code as a **zero padded string**
(`"01"`, not `1`). Writing this column as an integer is the single most common
validation failure.

Puerto Rico (`"72"`) is valid for the three hosp targets only. NSSP does not
publish ED visit data for Puerto Rico.

### `output_type`

Always `quantile` for this hub.

### `output_type_id`

The quantile probability level. All 23 of:

```
0.01, 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50,
0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.975, 0.99
```

R:

```r
quantile_levels <- c(0.01, 0.025, seq(0.05, 0.95, 0.05), 0.975, 0.99)
```

Python:

```python
quantile_levels = [0.01, 0.025] + [round(0.05 * i, 2) for i in range(1, 20)] + [0.975, 0.99]
```

### `value`

The predicted quantile: the inverse CDF of the predictive distribution at
`output_type_id`. For example, the 0.025 and 0.975 quantiles bound the central 95%
prediction interval.

- For **hosp** targets: a non negative number.
- For **ED visit** targets: a **decimal proportion between 0 and 1**.

> [!WARNING]
> ED targets are proportions, not percentages. If your model produces `2.31` meaning
> 2.31%, submit `0.0231`. Values above 1 will fail validation; values between 0 and 1
> that were meant as percentages will pass validation and score very badly.

Values must be non decreasing across increasing `output_type_id` within a
target/location/horizon.

## Example

```csv
reference_date,target,horizon,location,target_end_date,output_type,output_type_id,value
2026-01-03,wk inc flu hosp,0,US,2026-01-03,quantile,0.01,12043
2026-01-03,wk inc flu hosp,0,US,2026-01-03,quantile,0.025,12511
2026-01-03,wk inc flu hosp,0,US,2026-01-03,quantile,0.5,15220
2026-01-03,wk inc flu hosp,0,US,2026-01-03,quantile,0.975,19387
2026-01-03,wk inc flu hosp,0,US,2026-01-03,quantile,0.99,20455
2026-01-03,wk inc covid prop ed visits,1,06,2026-01-10,quantile,0.01,0.0104
2026-01-03,wk inc covid prop ed visits,1,06,2026-01-10,quantile,0.5,0.0163
2026-01-03,wk inc covid prop ed visits,1,06,2026-01-10,quantile,0.99,0.0241
```

(Rows elided for brevity; a real file carries all 23 quantiles per
target/location/horizon.)

## Validation

### On pull request

Opening a pull request that touches `model-output/` or `model-metadata/` triggers
[`validate-submission.yaml`](../.github/workflows/validate-submission.yaml), which
runs [`hubValidations`](https://github.com/hubverse-org/hubValidations). Fix any
reported errors and push again; the check re-runs.

### Locally, before you push

```r
# install.packages("hubValidations", repos = c("https://hubverse-org.r-universe.dev", getOption("repos")))

hubValidations::validate_submission(
  hub_path  = ".",
  file_path = "dmaprime-gam/2026-01-03-dmaprime-gam.csv"
)
```

`file_path` is relative to `model-output/`. Run it from the hub root.

## Deadline and late submissions

The submission window opens **Sunday** and closes **Wednesday at 11:59pm
US/Eastern**, which is `reference_date - 3`. This is enforced by `submissions_due`
in `hub-config/tasks.json`, so a pull request opened after the deadline will fail
validation.

Forecasting in something close to real time is the point of the exercise, so late
submissions are not accepted for scoring. If you need to correct an already merged
forecast, open a pull request explaining the change; corrections are handled case by
case and noted in the evaluation.

## Evaluation

Forecasts are scored with [`scoringutils`](https://epiforecasts.io/scoringutils/)
against `target-data/oracle-output.parquet`:

- **Weighted Interval Score (WIS)**, skill across the full predictive distribution
- **Absolute error of the median**, point accuracy
- **95% prediction interval coverage**, calibration

Because every model forecasts the same targets in the same format, these scores are
directly comparable. Two caveats:

- `scoringutils::score()` returns a per forecast `ae_median`. **MAE only exists
  after averaging** across forecasts, so it appears in a by horizon or by model
  summary, not in the raw output.
- `scoringutils` does **not** compute 95% interval coverage by default for the
  0.025 / 0.975 quantiles. Request it explicitly.

Counts and proportions are on wildly different scales, so **do not average WIS
across the hosp and ED target families**. Compare within a target, or use relative
WIS against a shared baseline.
