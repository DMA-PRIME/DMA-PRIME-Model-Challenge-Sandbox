# DMA-PRIME Model Challenge

A collaborative respiratory disease forecasting challenge run by the
**Clemson University Center for Public Health Modeling and Response (DMA-PRIME)**,
in the Department of Public Health Sciences.

The challenge is built to [hubverse](https://hubverse.io/) standards and modeled on
the CDC's [FluSight](https://github.com/cdcepi/FluSight-forecast-hub) and
[COVID-19 Forecast Hub](https://github.com/CDCgov/covid19-forecast-hub) challenges,
so that a forecast written for this hub is directly portable to those hubs.

> [!IMPORTANT]
> **Everything in this repository is public.** The target data, the hub
> configuration, every submitted forecast, and every evaluation score are open and
> world readable. Do not place anything sensitive, embargoed, or personally
> identifiable in this repository. All source data are public CDC surveillance
> products; no restricted or pre release data are used here.

> [!NOTE]
> This challenge is a research and training exercise. Forecasts collected here
> are **not** CDC submissions and are **not** intended to inform public health
> decisions.

## What you forecast

Six targets, spanning three pathogens and two surveillance streams:

| Target ID | Units | Source | Locations |
|---|---|---|---|
| `wk inc covid hosp` | count | NHSN | 53 |
| `wk inc flu hosp` | count | NHSN | 53 |
| `wk inc rsv hosp` | count | NHSN | 53 |
| `wk inc covid prop ed visits` | proportion | NSSP | 52 |
| `wk inc flu prop ed visits` | proportion | NSSP | 52 |
| `wk inc rsv prop ed visits` | proportion | NSSP | 52 |

- **Hospital admission targets** are the weekly count of new laboratory confirmed
  admissions for the pathogen, reported to CDC's
  [National Healthcare Safety Network (NHSN)](https://www.cdc.gov/nhsn/index.html).
- **ED visit targets** are the weekly proportion of emergency department visits due
  to the pathogen, reported to CDC's
  [National Syndromic Surveillance Program (NSSP)](https://www.cdc.gov/nssp/index.html).

> [!WARNING]
> **ED targets are proportions, not percentages.** CDC publishes these as a
> percentage (for example `2.31`, meaning 2.31%). Following CovidHub and FluSight,
> this hub stores, accepts, and scores them as a **decimal proportion** (`0.0231`),
> constrained to the interval [0, 1]. Submitting percentages will validate but will
> score catastrophically.

**Locations.** The nation (`US`), the 50 states, the District of Columbia, and
Puerto Rico, coded as 2 digit FIPS with `"US"` for national. See
[`auxiliary-data/locations.csv`](auxiliary-data/locations.csv). Puerto Rico is
available for the hospital admission targets only: NSSP does not publish ED visit
data for Puerto Rico, so `location = "72"` is deliberately excluded from the ED
model task rather than left open to forecasts that could never be scored.

**Horizons.** 0, 1, 2, and 3 weeks ahead. Submitting all four is encouraged but not
required.

**Reference dates and the submission window.** The `reference_date` is the Saturday
that ends the submission week. The window opens the preceding Sunday and closes
**Wednesday at 11:59pm US/Eastern** (`reference_date - 3`). Because NHSN's first
release covering `reference_date` does not appear until the following Wednesday,
**horizon 0 is a nowcast**: it predicts the week you are currently in, for which no
data have been published yet.

> **target_end_date = reference_date + horizon x 7 days**

Weeks follow the
[CDC MMWR epidemiological week](https://wwwn.cdc.gov/nndss/document/MMWR_Week_overview.pdf)
definition, running Sunday through Saturday. Standard packages convert between
calendar dates and epidemic weeks: [MMWRweek](https://cran.r-project.org/web/packages/MMWRweek/)
and [lubridate](https://lubridate.tidyverse.org/reference/week.html) for R,
[pymmwr](https://pypi.org/project/pymmwr/) and [epiweeks](https://pypi.org/project/epiweeks/)
for Python.

**Seasons.** The challenge runs year round. Reference dates are organized by
respiratory virus season following the NHSN convention: season Y/Y+1 runs from the
Saturday ending MMWR week 40 of year Y through the Saturday ending MMWR week 39 of
year Y+1. All seasons share a single round object in
[`hub-config/tasks.json`](hub-config/tasks.json), matching FluSight's layout, so
every reference date appears in one list.

| Season | First reference date | Last reference date | Rounds |
|---|---|---|---|
| 2025-2026 | 2025-10-04 | 2026-10-03 | 53 |
| 2026-2027 | 2026-10-10 | 2027-10-02 | 52 |
| 2027-2028 | 2027-10-09 | 2028-09-30 | 52 |

157 reference dates in total, every Saturday from 2025-10-04 through 2028-09-30
with no gaps between seasons.

To add a season, regenerate the config rather than editing dates by hand (see
[`hub-config/README.md`](hub-config/README.md)).

## Submitting a forecast

Submissions follow the hubverse model output schema:

```
reference_date, target, horizon, location, target_end_date, output_type, output_type_id, value
```

Place forecasts in `model-output/<team>-<model>/`, one file per reference date named
`<reference_date>-<team>-<model>.csv` (or `.parquet`), with a matching
`model-metadata/<team>-<model>.yml`. Open a pull request; validation runs
automatically.

Full instructions are in [`model-output/README.md`](model-output/README.md) and
[`model-metadata/README.md`](model-metadata/README.md).

## Target data

Two files in [`target-data/`](target-data/), both regenerated automatically every
Wednesday:

- **`time-series.parquet`** is the vintaged observed series. Every Wednesday the
  pipeline appends a new `as_of` snapshot holding the full observed history as it
  stood that day, which is what lets the dashboard show a forecaster what was
  actually visible at their reference date, and what makes reporting revisions
  measurable.
- **`oracle-output.parquet`** is the scoring truth: the most recently reported
  value for each location, week, and target.

The as pulled CDC extracts are preserved unmodified in
[`auxiliary-data/`](auxiliary-data/). See
[`target-data/README.md`](target-data/README.md) for the schemas and
[`auxiliary-data/README.md`](auxiliary-data/README.md) for the raw archives.

### Reporting revisions and why timing matters

NHSN admissions are **revised after they are first published**, an effect called
backfill. "The admissions count for week W" is therefore not a single number; it
depends on when you ask. A model that trains on today's settled values and then
"forecasts" a past week will look far more accurate than any real time forecaster
could have been, because it can see values that were still settling at the time.

The reporting calendar behind this:

- Facilities report a Sunday through Saturday week to NHSN by **Tuesday 11:59pm PT**
  of the following week.
- CDC publishes **preliminary** figures on **Wednesday** and **finalized** figures on
  **Friday or Saturday**.
- Revisions to a given week continue after first publication.
- NSSP ED visit data refresh on **Friday**.

The `as_of` column in `time-series.parquet` is the honesty mechanism. To reproduce
what a forecaster could legitimately have used at reference date `R`, filter to
`as_of == R - 3` (the Wednesday deadline) rather than taking the latest values.

## Evaluation

Forecasts are scored with [`scoringutils`](https://epiforecasts.io/scoringutils/)
against `target-data/oracle-output.parquet`. Reported metrics:

- **Weighted Interval Score (WIS)**, overall skill across the predictive distribution
- **Absolute error of the median**, point accuracy
- **95% prediction interval coverage**, calibration

Two things to know before reading scores:

- `scoringutils::score()` returns a per forecast `ae_median`. **MAE only exists after
  averaging** across forecasts, so it appears in a by horizon or by model summary,
  not in the raw score output.
- `scoringutils` does **not** compute 95% interval coverage by default for the
  0.025 / 0.975 quantiles. It must be requested explicitly.

Counts and proportions are not on a comparable scale, so **never average WIS across
the hosp and ED target families**. Compare within a target, or use relative WIS
against a common baseline.

## Automation

| Workflow | Trigger | Purpose |
|---|---|---|
| [`update-target-data.yaml`](.github/workflows/update-target-data.yaml) | Wednesdays 18:00 UTC | Pull, clean, and commit NHSN + NSSP target data |
| [`validate-submission.yaml`](.github/workflows/validate-submission.yaml) | PRs touching `model-output/` or `model-metadata/` | `hubValidations::validate_pr()` |
| [`validate-config.yaml`](.github/workflows/validate-config.yaml) | PRs touching `hub-config/` | `hubAdmin::ci_validate_hub_config()` |
| [`cache-hubval-deps.yaml`](.github/workflows/cache-hubval-deps.yaml) | Push to main, nightly | Warm the dependency cache |

To refresh target data by hand, run from the hub root:

```sh
Rscript scripts/get_target_data.R
```

## Acknowledgments

This repository follows the guidelines and standards of
[the hubverse](https://hubverse.io), which provides data formats and open source
tooling for modeling hubs. The hub structure descends from Nick Reich's
[SISMID ILI forecasting sandbox](https://github.com/reichlab/sismid-ili-forecasting-sandbox)
by way of the DMA-PRIME SISMID Human-AI Teaming forecasting sandbox, with the
targets rebuilt around NHSN admissions and NSSP ED visits for COVID-19, influenza,
and RSV.
