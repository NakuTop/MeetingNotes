# Local validation safety

The user requires background-only testing. Do not run UI automation, launch
visible test windows, activate apps, synthesize keyboard/mouse input, or change
the user's current input method/permissions. Use `Scripts/test_in_background.sh`
for unit tests. Its two interactive floating-panel tests are deliberately skipped;
report them as not run, never passed. Packaged-app recording/screenshot acceptance
remains a user-controlled manual gate. Do not install or launch a candidate app
without separate approval. Preserve existing work and do not publish implicitly.
