# __DOMAIN_TITLE__ Architecture

<!-- SKELETON: replace. Open each diagram with one sentence that says which
     question it answers. Show the core artifact (a message, an aspect, a
     model output) with a field table and a real sample. Record product
     behaviour the code depends on as "verified on <date>". -->

Datasets follow semantic medallion stages — the domain (`__DOMAIN_TAG__`) is a
Dataform tag, not a dataset.

## Pipeline Overview

What gets built, and how it is connected.

<!-- A mermaid graph of the stages and products. -->

## Data Flow

In what order things happen, and which calls are made.

<!-- A mermaid sequence diagram. -->

## Key components

| Stage | Object | Purpose |
| --- | --- | --- |
| | | |

## Data quality

| Folder | type | Semantics |
| --- | --- | --- |
| `assertions/` | `"assertion"` | Hard fail — returned rows fail the run |
| `monitoring/` | `"view"` | Warning only — never blocks |
