# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C3: every skill ships the framework's MIT LICENSE (dotsteward contributors),
# byte for byte.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
st_expect_clean sc_check_license "$skill"

printf '\n' >>"$skill/LICENSE"
st_expect_finding 'C3 example-skill/LICENSE: differs from the framework LICENSE' sc_check_license "$skill"
rm "$skill/LICENSE"
st_expect_finding 'C3 example-skill: LICENSE is missing or not a regular file' sc_check_license "$skill"
ln -s ../../LICENSE "$skill/LICENSE"
st_expect_finding 'C3 example-skill: LICENSE is missing or not a regular file' sc_check_license "$skill"
rm "$skill/LICENSE"

# The framework LICENSE itself must be the MIT text of dotsteward contributors.
sed 's/dotsteward contributors/Someone Else/' "$DS_REPO_ROOT/LICENSE" >"$SC_REPO_ROOT/LICENSE"
cp "$SC_REPO_ROOT/LICENSE" "$skill/LICENSE"
st_expect_finding 'C3 framework LICENSE: not the MIT license of dotsteward contributors' sc_check_license "$skill"
sed 's/^MIT License$/Other License/' "$DS_REPO_ROOT/LICENSE" >"$SC_REPO_ROOT/LICENSE"
cp "$SC_REPO_ROOT/LICENSE" "$skill/LICENSE"
st_expect_finding 'C3 framework LICENSE: not the MIT license of dotsteward contributors' sc_check_license "$skill"
