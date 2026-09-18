Live validation - omp harness fixture ancestry isolation
base 83e4b56 -> target 3c89d6b

The product surface driven: bin/fm-harness.sh, the harness-detection CLI, plus
tests/fm-omp-harness.test.sh run the way a developer and CI run it.

The omp session was simulated the same way the suite itself proves is genuine:
a symlink named `omp` pointing at /bin/bash. Production confirms it is real
evidence before any suite runs - see production-detection-parity.txt, row
"inside omp sess -> omp".

  before-base-inside-omp-session.txt   the reported failure, reproduced
  after-target-inside-omp-session.txt  the same run, now fully green
  adversarial-deep-omp-session.txt     the same, with the session 5 levels up
  repeatability.txt                    4 more runs, inside and outside, identical
  production-detection-parity.txt      detection output byte-identical base vs target
  seam-cli-transcript.txt              FM_HARNESS_PS_BIN unset / empty / stopping / missing
  new-isolation-test-is-a-real-guard.txt  the new test alone: green clean, red on a broken seam
  mutation-isolation-guard.txt         seam removed -> red; ps argument form changed -> green
  isolation-self-verifies-in-ci.txt    both mutants judged with NO omp session present
  base-path-knob-in-force.txt          FM_TEST_BASE_PATH now feeds the fixture toolchain
  adversarial-host-without-ps.txt      a host with no ps aborts the suite loudly
  sibling-precedence-suite.txt         tests/fm-harness-precedence.test.sh still green
