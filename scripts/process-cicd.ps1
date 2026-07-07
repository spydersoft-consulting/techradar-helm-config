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
#    X.Y.Z-beta.<n>) -> goes to the "beta" branch here, environment "test".
#    Kept on a separate branch (not helm-config's own "main") so it can
#    never reach the stage/production promotion stages in release.yml,
#    which only trigger off pushes to this repo's "main".
#  - anything else (a tag push on the app repo) -> a release build -> goes
#    to this repo's "main" branch, environment "stage", eligible for the
#    existing stage->production promotion in release.yml.
if ($shortBranchName -eq "main") {
    $environment = "test"
    $helmBranch = "beta"
    $commitMessagePrefix = "BETA"
}
else {
    $environment = "stage"
    $helmBranch = "main"
    $commitMessagePrefix = "RELEASE"
}

Write-Host "Processing $branchName -> environment $environment, helm branch $helmBranch"
$branchExists = ((git ls-remote origin "refs/heads/$helmBranch" | Measure-Object -line).Lines -gt 0)
if ($branchExists) {
    Write-Host "Using existing branch -> $helmBranch"
    Invoke-Expression "git fetch"
    Invoke-Expression "git checkout $helmBranch"
    Invoke-Expression "git reset --hard"
    # Only a branch that already existed on the remote has upstream tracking
    # info to rebase against -- a brand-new local branch doesn't yet, and
    # `git pull --rebase` would just fail noisily (harmlessly) for it.
    Invoke-Expression "git pull --rebase"
    if ($helmBranch -ne "main") {
        # beta is long-lived and only ever receives tag-bump commits from
        # this script -- without merging main in, it silently drifts further
        # from main's structural changes (chart references, helmfile
        # definitions, etc.) every time main changes, and test stops
        # reflecting main's actual current structure. Confirmed: this
        # already happened once -- a chart split landed on main and beta
        # kept rendering the pre-split single-release helmfile for days
        # until this fix.
        Invoke-Expression "git merge origin/main --no-edit"
    }
}
else {
    Write-Host "Creating new local branch -> $helmBranch"
    Invoke-Expression "git checkout -b $helmBranch"
}
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
Invoke-Expression "git push origin $helmBranch"