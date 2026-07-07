param (
    [string] $branchName="refs/heads/main",
    # Comma-joined, e.g. "data_api=1.2.3,frontend=1.2.3". Split here rather
    # than relying on the CLI to bind a [string[]] from whitespace-separated
    # tokens -- that approach silently only ever captured the first tag
    # once this script started receiving more than one (confirmed: passing
    # a space-joined string through unquoted still bound as one element,
    # not two, for reasons not fully understood -- quoting the whole
    # comma-joined string and splitting it here sidesteps CLI binding
    # entirely and is easy to reason about).
    [string] $tagsCollection="",
    [string] $message="Commit Message"
)

$tags = $tagsCollection.Split(",")

$shortBranchName = $branchName.Replace("refs/heads/", "")

# Two build shapes reach this script (feature/* branches no longer deploy):
#  - a push to the app repo's main branch -> a beta build (GitVersion tags
#    X.Y.Z-beta.<n>) -> updates environments/test/images.yaml.
#  - anything else (a tag push on the app repo) -> a release build ->
#    updates environments/stage/images.yaml.
# Both always commit to this repo's own main -- there used to be a
# separate persistent "beta" branch for the first case, kept apart from
# main so a beta update could never reach the stage->production promotion
# in release.yml. That branch only ever received tag-bump commits, so it
# silently drifted from main's own structural changes over time (a chart
# split landed on main and the branch kept rendering the pre-split
# definition for days before anyone noticed). Replaced by path-based
# pipeline triggers instead (pipeline-test.yml / pipeline-main.yml, each
# triggered only by its own environment's tag file changing) -- the same
# safety property (beta can't reach production) now comes from which
# pipeline definition even fires, not from which branch the commit is on.
if ($shortBranchName -eq "main") {
    $environment = "test"
    $commitMessagePrefix = "BETA"
}
else {
    $environment = "stage"
    $commitMessagePrefix = "RELEASE"
}

Write-Host "Processing $branchName -> environment $environment"
Invoke-Expression "git fetch"
Invoke-Expression "git checkout main"
Invoke-Expression "git reset --hard"
Invoke-Expression "git pull --rebase"
$imageFile = "./environments/$environment/images.yaml"

Write-Host "Replacing tags in $imageFile"
$imagePath = (Resolve-Path $imageFile).Path
Push-Location ./scripts

# Must start as an explicit array: $imageArgs += "..." on an uninitialized
# ($null) variable does string concatenation, not array-append, so a
# second tag lands glued directly onto the first with no separating space
# (e.g. "--value imageTags.data_api=1--value imageTags.frontend=1"),
# which edit-value.py's argparse then rejects as one unrecognized
# argument. Confirmed via a real build: this silently dropped every tag
# past the first whenever more than one was ever passed.
$imageArgs = @()
foreach ($tag in $tags) {
    $tagSplit = $tag.Split("=")
    $imageArgs += "--value imageTags.$($tagSplit[0])=$($tagSplit[1])"
}

Invoke-Expression "python ./edit-value.py $imageArgs $imagePath"
Pop-Location

Invoke-Expression "git add $imageFile"

Invoke-Expression "git commit -m '$commitMessagePrefix - $message'"
Invoke-Expression "git push origin main"