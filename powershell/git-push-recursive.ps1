# This powershell script is used to push mass updates to
# github, this is especially useful when switching docker
# base image tag name. 

# define github repository root folder
$github_repo_root = "C:\Scripts\Github"

# define modified filename to track for changes (called staging in github)
$github_staged_filename = "Dockerfile"

# define description for mass commits
$github_commit_msg = "switching to latest built base image"

Write-Host "Starting..."

# set up all the environment variables
Write-Host "Setting up GitHub Environment"
. (Resolve-Path "$env:LOCALAPPDATA\GitHub\shell.ps1")

# set up Posh-Git
Write-Host "Setting up Posh-Git"
. (Resolve-Path "$env:github_posh_git\profile.example.ps1")

git config --global credential.helper wincred

# change to root folder
cd $github_repo_root

# iterate over folders issuing a git commit and push
Get-ChildItem -Recurse -Depth 2 -Force | 
 Where-Object { $_.Mode -match "h" -and $_.FullName -like "*\.git" } |
 ForEach-Object {
    cd $_.FullName
    cd ../
    $current_absolute_path = (Get-Item -Path ".\" -Verbose).FullName
    Write-Host "Looking for local changes in $current_absolute_path..."
    # this command ensures we track changes to existing files (staging)
    git add $github_staged_filename
    # this command checks for local differences to HEAd (github remote)
    git diff-index --quiet HEAD -- $github_staged_filename
    if ($LastExitCode -ne 0) {
        Write-Host "Changes detected, committing change with message '$github_commit_msg'..."
        # this command commits certain file(s) with a commit message
        git commit $github_staged_filename -m $github_commit_msg
        # this command pushes the local changes to github
        Write-Host "Pushing local changes from $current_absolute_path to GitHub..."
        git push origin master
    }
    cd ../
 }

Write-Host "Complete"