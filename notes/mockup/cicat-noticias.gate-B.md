No stray links bypass the `id` param. The changes compile cleanly (`tsc -b --force`), lint cleanly (`oxlint`), all referenced assets exist, and the id/not-found/related-articles/copy-link logic all check out against edge cases (missing id, empty id, unknown id, empty NEWS filter result). I found no concrete defects.

GATE: PASS
