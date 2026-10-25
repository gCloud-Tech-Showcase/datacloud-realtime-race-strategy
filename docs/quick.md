# F1 Pit Wall: Real-Time Race Strategy Quick Reference

<!-- SKELETON: replace with commands and queries that prove this domain works.
     Number each section. Show real sample output from a fresh-project run.
     Include at least one check that tells "the pipeline ran" apart from
     "the result is correct". -->

Copy-paste commands and queries, with sample output. Run them from the repository root, with `PROJECT_ID` set to your project.

> **Sample output only.** Values change with every run. Check the shape of the output, not the exact values.

---

## 1. Rerun the pipeline

The first `tofu apply` runs the pipeline once. To run it again, open the **Run Pipeline** notebook in BigQuery Studio and run all cells, or run the script:

```bash
cd infra
PROJECT=$(tofu output -raw project_id) REGION=us-central1 \
REPO=$(tofu output -raw dataform_repository_name) \
RUNNER_SA="dataform-runner@$(tofu output -raw project_id).iam.gserviceaccount.com" \
  bash scripts/run_pipeline.sh
```

---

## 2. Row counts

```sql
SELECT COUNT(*) FROM `serving.<table>`;
```

---

## 3. Data quality

Both must return no rows:

```sql
SELECT * FROM `assertions.<assertion_name>`;
```

---

## 4. Monitoring

Rows here are expected. Watch the trend:

```sql
SELECT * FROM `assertions.<monitoring_view>`;
```

---

## Navigation

[← Overview](README.md) | [Topic](01-topic.md) | [Architecture](architecture.md)
