# Topic

<!-- SKELETON: the step-by-step guide. Rename the file and the title to the
     topic (for example 01-schema-changes.md), never to a role such as
     01-demo.md. Write for someone running it in their own project, in the
     second person. No time estimates.

     For every edit the reader makes, give the file and line, the before
     and after as a diff block, and an optional perl one-liner (perl -pi -e
     works on macOS and Linux, sed -i does not). Run each one-liner on a
     throwaway copy first.

     Add 5 or 6 console screenshots in docs/images/ at the moments that
     matter, cropped and with a dated caption. The text must stand without
     them.

     Add a notebook twin as notebooks/01-<topic>.ipynb with the same steps
     in the same order, and say near the top that the reader can follow it
     under BigQuery Studio > Notebooks instead.

     Give every SQL block a saved query in queries/<NN>-<name>.sql, with
     "-- <NN> <Topic>: <what it shows>" as its first line, and name the
     saved query next to the block. -->

One sentence on what the reader does in this guide.

---

## Step 1: <What the reader does>

In `<file>`, line <N>, in the `<named block>`:

```diff
-<line as it is now>
+<line after the change>
```

Or make the same edit from the terminal:

```bash
perl -pi -e 's/<before>/<after>/' <file>
```

Then apply and check:

```bash
(cd infra && tofu apply)
```

<!-- What the reader sees, and why it matters. -->

---

## Key Takeaways

| Capability | Technology | Business value |
| --- | --- | --- |
| | | |

---

## What's Next

<!-- 2 to 4 experiments the reader can try on their own. Ask them to predict
     the result first. Give exact edits and undo steps. -->

---

## Navigation

[← Overview](README.md) | [Quick Reference](quick.md) | [Architecture](architecture.md)
