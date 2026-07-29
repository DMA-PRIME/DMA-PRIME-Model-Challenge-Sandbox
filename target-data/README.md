# Target data

Truth data for the **DMA-PRIME Model Challenge**, in
[standard hubverse target data format](https://docs.hubverse.io/en/latest/user-guide/target-data.html).

The layout is declared in
[`hub-config/target-data.json`](../hub-config/target-data.json): the observable unit
is `(target_end_date, location, target)`, the date column is `target_end_date`, and
`time-series` is versioned by `as_of` while `oracle-output` is not.

**Everything in this folder is public.** Both files are regenerated automatically
every Wednesday by
[`.github/workflows/update-target-data.yaml`](../.github/workflows/update-target-data.yaml),
which runs [`scripts/get_target_data.R`](../scripts/get_target_data.R). Do not edit
them by hand; changes will be overwritten on the next run.

## Files

### `time-series.parquet`

The **vintaged** observed series. Each Wednesday the pipeline appends one new
`as_of` snapshot containing the full observed history as it stood that morning. The
history repeats in every snapshot, which is what
[predtimechart](https://docs.hubverse.io/en/latest/user-guide/dashboards.html) needs
in order to render, and what makes reporting revisions measurable.

| Column | Type | Description |
|---|---|---|
| `target_end_date` | date | Saturday ending the MMWR week observed |
| `observation` | double | Observed value |
| `location` | string | 2 digit FIPS, or `"US"` for national |
| `as_of` | date | Wednesday this snapshot was retrieved |
| `target` | string | One of the six target IDs |

### `oracle-output.parquet`

The scoring truth: the most recently reported value for each location, week, and
target. This is what `scoringutils` evaluates forecasts against.

| Column | Type | Description |
|---|---|---|
| `location` | string | 2 digit FIPS, or `"US"` |
| `target_end_date` | date | Saturday ending the MMWR week observed |
| `target` | string | One of the six target IDs |
| `output_type` | string | `"quantile"` |
| `oracle_value` | double | Observed value |
| `output_type_id` | string | `NA` |

## Targets and units

| Target | Units | Range | Source |
|---|---|---|---|
| `wk inc covid hosp` | count | >= 0 | NHSN |
| `wk inc flu hosp` | count | >= 0 | NHSN |
| `wk inc rsv hosp` | count | >= 0 | NHSN |
| `wk inc covid prop ed visits` | proportion | [0, 1] | NSSP |
| `wk inc flu prop ed visits` | proportion | [0, 1] | NSSP |
| `wk inc rsv prop ed visits` | proportion | [0, 1] | NSSP |

> [!WARNING]
> CDC publishes the ED visit metrics as **percentages**. This hub stores them as
> **decimal proportions**, matching CovidHub and FluSight. The division by 100
> happens once, in `clean_nssp()` inside
> [`scripts/get_target_data.R`](../scripts/get_target_data.R), and nowhere else.

## Sources and release cadence

| Source | Dataset | Published |
|---|---|---|
| NHSN, finalized | [`ua7e-t2fy`](https://data.cdc.gov/Public-Health-Surveillance/Weekly-Hospital-Respiratory-Data-HRD-Metrics-by-Ju/ua7e-t2fy/about_data) | Friday / Saturday |
| NHSN, preliminary | [`mpgq-jmmr`](https://data.cdc.gov/Public-Health-Surveillance/Weekly-Hospital-Respiratory-Data-HRD-Metrics-by-Ju/mpgq-jmmr/about_data) | Wednesday |
| NSSP ED visits | [`rdmq-nq56`](https://data.cdc.gov/Public-Health-Surveillance/NSSP-Emergency-Department-Visit-Trajectories-by-St/rdmq-nq56/about_data) | Friday |

Finalized NHSN values always win. Preliminary values fill only the weeks the
finalized release does not carry yet, which on a Wednesday run is the week ending
the previous Saturday. This is what makes a fresh value available at the submission
deadline while keeping settled weeks on their finalized figures.

## Known coverage gaps

- **Puerto Rico has no ED visit data.** NSSP publishes state level ED percentages
  for the nation, the 50 states, and DC, but not Puerto Rico. `location = "72"` is
  therefore excluded from the ED model task in
  [`hub-config/tasks.json`](../hub-config/tasks.json). It remains available for the
  hospital admission targets.
- **RSV admissions were voluntary before 2024-11-01.** RSV reporting to NHSN became
  mandatory alongside COVID-19 and influenza on 1 November 2024. Earlier RSV values
  are sparse and are not comparable in coverage to later ones.
- **NSSP history begins 2022-10-01.** Earlier weeks are not available.

## Reproducing a real time view

To recover what a forecaster could legitimately have used at reference date `R`,
filter the vintaged series to the snapshot taken at that week's Wednesday deadline:

```r
library(dplyr)
library(arrow)

R <- as.Date("2026-01-03")

visible_at_deadline <- read_parquet("target-data/time-series.parquet") |>
  filter(as_of == R - 3, target_end_date <= R)
```

Comparing that against `oracle-output.parquet` for the same weeks shows the size of
the backfill correction, which is largest near a season peak.

## Regenerating manually

From the hub root:

```sh
Rscript scripts/get_target_data.R
```

Requires `dplyr`, `tidyr`, `readr`, and `arrow`. Re-running on the same Wednesday
replaces that day's snapshot rather than duplicating it, so the script is safe to
run more than once. Optional environment variables:

| Variable | Default | Effect |
|---|---|---|
| `NSSP_SOURCE` | `cdc` | `covidhub` pulls the Wednesday NSSP mirror instead, which is one week fresher |
| `ARCHIVE_RAW_SNAPSHOTS` | unset | `true` also writes a dated copy of each raw pull |
| `SOCRATA_APP_TOKEN` | unset | Raises data.cdc.gov rate limits |
