# Hub configuration

Configuration for the **DMA-PRIME Model Challenge**, following the
[hubverse hub configuration guide](https://docs.hubverse.io/en/latest/user-guide/hub-config.html).
All files here are public. Changes are validated automatically on pull request by
[`validate-config.yaml`](../.github/workflows/validate-config.yaml).

| File | Purpose |
|---|---|
| `admin.json` | Hub name, maintainer, contact, repository, accepted file formats |
| `tasks.json` | Rounds, task IDs, targets, output types, submission windows |
| `target-data.json` | Declares the observable unit, date column, and `as_of` versioning |
| `model-metadata-schema.json` | Schema each `model-metadata/<team>-<model>.yml` must satisfy |

All configs are pinned to hubverse schema **v6.0.0**.

## `target-data.json`

This file tells hubverse tooling how to read `target-data/` without inferring the
schema by scanning files, which is what makes the `as_of` versioning legible to
dashboards and to `hubEvals`.

```json
{
    "observable_unit": ["target_end_date", "location", "target"],
    "date_col": "target_end_date",
    "versioned": true,
    "oracle-output": { "has_output_type_ids": true, "versioned": false }
}
```

- `observable_unit` is the minimum set of columns identifying one observation. The
  `as_of` column is deliberately **not** part of it: it is a versioning column, not
  a task ID.
- `versioned: true` globally, because `time-series.parquet` carries one `as_of`
  snapshot per Wednesday.
- `oracle-output` overrides that with `versioned: false`. Oracle output must hold
  exactly one value per observable unit, otherwise a forecast could be scored more
  than once against different vintages of the same week.

## `tasks.json` structure

Two model tasks per round, split so that the two target families can carry
different value constraints and different location sets:

| Model task | Targets | Value constraint | Locations |
|---|---|---|---|
| Hospital admissions | `wk inc {covid,flu,rsv} hosp` | `double`, minimum 0 | 53 |
| ED visits | `wk inc {covid,flu,rsv} prop ed visits` | `double`, minimum 0, **maximum 1** | 52 |

Puerto Rico (`72`) is absent from the ED task because NSSP does not publish ED visit
data for Puerto Rico. Both tasks use 23 required quantiles, horizons 0 through 3,
and `submissions_due` relative to the reference date (`start: -6`, `end: -3`), which
opens the window on Sunday and closes it Wednesday.

**A single round object** holds every reference date, which is how FluSight itself
is laid out. All 157 reference dates appear in one `reference_date` list running
2025-10-04 through 2028-09-30, every Saturday with no gaps.

Seasons are still the organizing idea, they are just documented rather than encoded
as separate rounds: season Y/Y+1 spans the Saturday ending MMWR week 40 of year Y
through the Saturday ending MMWR week 39 of year Y+1, following the NHSN
convention. The generator computes those boundaries and concatenates them.

If you would rather have one round object per season, drop the `--single-round`
flag below. Be aware that splitting the dates across rounds makes the config much
harder to read: the later seasons end up hundreds of lines down the file, and it is
easy to glance at the first list and conclude the hub stops early.

## Target order matters for the dashboard

`PATHOGENS` in `scripts/gen_tasks.py` puts **influenza first**, and that is
deliberate. predtimechart uses the first target as `initial_target_var` but derives
`initial_as_of` from the latest reference date across *all* targets, then checks it
against only the first target's available dates. A first target with fewer forecasts
than the others fails the dashboard build with `initial_as_of not in
available_as_ofs`. Keep the most widely forecast target first.

## Adding a season

`tasks.json` contains several hundred generated dates. Do not hand edit them.
Regenerate instead, from the hub root:

```sh
python3 scripts/gen_tasks.py auxiliary-data/locations.csv hub-config/tasks.json 2025 2026 2027 2028 --single-round
```

The trailing arguments are season start years. The generator computes MMWR week
boundaries, expands reference dates and the implied `target_end_date` values, and
applies the Puerto Rico exclusion to the ED task. Re-running with the existing
season list plus one more is the intended way to extend the challenge.

Validate before opening a pull request:

```r
hubAdmin::validate_hub_config(".")
```
