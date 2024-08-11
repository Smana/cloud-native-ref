package main

import (
	"fmt"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
)

// getGitRoot returns the root directory of the current git repository using go-git library
func getGitRoot() (string, error) {
	repo, err := git.PlainOpen(".")
	if err != nil {
		return "", fmt.Errorf("failed to open git repository: %w", err)
	}

	worktree, err := repo.Worktree()
	if err != nil {
		return "", fmt.Errorf("failed to get worktree: %w", err)
	}

	return worktree.Filesystem.Root(), nil
}

func createAndCheckoutBranch(repoPath, branchName string) error {
	// Open the existing repository
	repo, err := git.PlainOpen(repoPath)
	if err != nil {
		return fmt.Errorf("could not open repository: %v", err)
	}

	// Get the working tree
	worktree, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("could not get working tree: %v", err)
	}

	// Create a new branch reference
	branchRef := plumbing.NewBranchReferenceName(branchName)

	// Checkout the new branch
	err = worktree.Checkout(&git.CheckoutOptions{
		Branch: branchRef,
		Create: true, // Creates the branch before checking it out
	})
	if err != nil {
		return fmt.Errorf("could not checkout branch: %v", err)
	}

	return nil
}
