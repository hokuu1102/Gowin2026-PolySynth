# T3 unmerged-branch audit (git cherry, patch-level)

> Date: 2026-10-01. worktrees 22. archive/* = 30 (left as-is).
> Method: `git cherry main <br>`; a `+` line means that PATCH is not in main; `-` means it is.

## IMPORTANT CAVEAT -- this overestimates

git cherry compares PATCHES. If a feature was reimplemented on main rather than
cherry-picked, its patch is absent and the branch shows `+` even though the FEATURE
is present. Several of these branches (feat/pins2, feat/pins3, feat/timing2,
feat/transpose, fix/calib-autotare, mutcheck, build/drum2) are known to have been
superseded this way. So this list is a CANDIDATE list, not a verdict: each branch
still needs a content check before it can be called truly unmerged.

| branch | unmerged patches | already in main | verdict |
|---|---|---|---|
| build/drum | 23 | 0 | CANDIDATE (23) |
| build/drum2 | 1 | 0 | CANDIDATE (1) |
| deliver | 0 | 0 | MERGED |
| docs/pinsfix | 14 | 0 | CANDIDATE (14) |
| feat/allocfix | 19 | 1 | CANDIDATE (19) |
| feat/drumpat | 13 | 0 | CANDIDATE (13) |
| feat/fx | 31 | 0 | CANDIDATE (31) |
| feat/looptiming | 4 | 0 | CANDIDATE (4) |
| feat/noise-wt | 1 | 0 | CANDIDATE (1) |
| feat/pins2 | 10 | 0 | CANDIDATE (10) |
| feat/pins3 | 14 | 0 | CANDIDATE (14) |
| feat/pitch-env | 0 | 1 | MERGED |
| feat/pool-src | 7 | 0 | CANDIDATE (7) |
| feat/pooldiag | 13 | 0 | CANDIDATE (13) |
| feat/s3-ble | 26 | 0 | CANDIDATE (26) |
| feat/score-arb | 0 | 1 | MERGED |
| feat/tailfix | 1 | 0 | CANDIDATE (1) |
| feat/timing2 | 12 | 1 | CANDIDATE (12) |
| feat/transdiag | 19 | 1 | CANDIDATE (19) |
| feat/transpose | 1 | 0 | CANDIDATE (1) |
| fix/calib-autotare | 1 | 0 | CANDIDATE (1) |
| local-backup-20260919 | 10 | 0 | CANDIDATE (10) |
| merge/t31bfinal | 14 | 0 | CANDIDATE (14) |
| mutcheck | 1 | 0 | CANDIDATE (1) |
| pr/1 | 0 | 0 | MERGED |
| pr/2 | 0 | 1 | MERGED |
| pr/3 | 0 | 0 | MERGED |
| pr/4 | 0 | 0 | MERGED |
| pr/5 | 2 | 0 | CANDIDATE (2) |
| step/B-timing | 2 | 0 | CANDIDATE (2) |
| step/C-transpose | 1 | 0 | CANDIDATE (1) |

## Candidate short list

- build/drum (23)
- build/drum2 (1)
- docs/pinsfix (14)
- feat/allocfix (19)
- feat/drumpat (13)
- feat/fx (31)
- feat/looptiming (4)
- feat/noise-wt (1)
- feat/pins2 (10)
- feat/pins3 (14)
- feat/pool-src (7)
- feat/pooldiag (13)
- feat/s3-ble (26)
- feat/tailfix (1)
- feat/timing2 (12)
- feat/transdiag (19)
- feat/transpose (1)
- fix/calib-autotare (1)
- local-backup-20260919 (10)
- merge/t31bfinal (14)
- mutcheck (1)
- pr/5 (2)
- step/B-timing (2)
- step/C-transpose (1)

## Not merged at all (no unmerged patches)

- deliver
- feat/pitch-env
- feat/score-arb
- pr/1
- pr/2
- pr/3
- pr/4

## SECOND ATTEMPT -- a method that does NOT work (recorded so nobody repeats it)

I tried to decide each candidate by the SIZE of its rtl/ diff against main:
`git diff --numstat main..<branch> -- rtl/`, expecting small differences to mean the
work had already been superseded.

IT DOES NOT WORK. Every one of the 24 candidates came back with a large NEGATIVE net
(deletions far exceeding insertions): build/drum -2791, feat/sx-ble -10131,
local-backup-20260919 -20283, pr/5 -13629, and so on. The reason is that main is now 72
commits ahead, so the diff shows main's NEW code as deletions. The magnitude is
dominated by how far main has moved, and says nothing about whether the branch's work
is present.

CONCLUSION, stated plainly: there is no cheap automatic criterion for "is this branch
truly unmerged". Patch-level git cherry over-reports (a reimplemented feature shows as
absent), and diff-size is meaningless for the reason above. Deciding this requires
reading each branch's actual change and comparing it against what main now does -- one
branch at a time, by hand. That is the honest state of this item: it is a REVIEW task,
not a script task.

Nothing was deleted or merged on the basis of either attempt. All 24 candidates and all
30 archive/* branches remain untouched.

