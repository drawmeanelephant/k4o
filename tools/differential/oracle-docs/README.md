# oracle-docs

Captured from the pinned knap 0.6.0 CLI (`tools/differential`), black-box
`knap help` output — the user-facing language reference the clean-room
implementation works from. Regenerate with:

```sh
cd tools/differential
for f in $(node_modules/.bin/knap help filters | awk 'NR>1 && $1 ~ /^[a-z]/ {print $1}'); do
  echo "=== $f ==="; node_modules/.bin/knap help filter "$f"
done > oracle-docs/filter-details.txt
```
