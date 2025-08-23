# Claude Command: Commit

This command helps you create well-formatted commits with conventional commit messages and emoji.

## Usage

To create a commit, just type:
```
/commit
```

Or with options:
```
/commit --no-verify
```

## What This Command Does

1. Unless specified with `--no-verify`, automatically runs pre-commit checks:
   - **Cleans Terraform temporary files** to avoid validation conflicts
   - **Silently sets up pre-commit environment** (uv venv, install pre-commit, install hooks)
   - **Only stops if environment setup fails** - otherwise proceeds automatically
   - Runs `pre-commit run --all-files` to validate configuration and security
   - **Analyzes any failing checks and provides detailed report with recommendations**
   - **Stops commit process if checks fail and suggests fixes**
2. Checks which files are staged with `git status`
3. If 0 files are staged, automatically adds all modified and new files with `git add`
4. Performs a `git diff` to understand what changes are being committed
5. Analyzes the diff to determine if multiple distinct logical changes are present
6. If multiple distinct changes are detected, suggests breaking the commit into multiple smaller commits
7. For each commit (or the single commit if not split), creates a commit message using emoji conventional commit format

## Best Practices for Commits

- **Verify before committing**: Ensure configuration is validated, security checks pass, and formatting is correct
- **Atomic commits**: Each commit should contain related changes that serve a single purpose
- **Split large changes**: If changes touch multiple concerns, split them into separate commits
- **Conventional commit format**: Use the format `<type>: <description>` where type is one of:
  - `feat`: A new feature
  - `fix`: A bug fix
  - `docs`: Documentation changes
  - `style`: Code style changes (formatting, etc)
  - `refactor`: Code changes that neither fix bugs nor add features
  - `perf`: Performance improvements
  - `test`: Adding or fixing tests
  - `chore`: Changes to the build process, tools, etc.
- **Present tense, imperative mood**: Write commit messages as commands (e.g., "add feature" not "added feature")
- **Concise first line**: Keep the first line under 72 characters
- **Emoji**: Each commit type is paired with an appropriate emoji:
  - ✨ `feat`: New feature
  - 🐛 `fix`: Bug fix
  - 📝 `docs`: Documentation
  - 💄 `style`: Formatting/style
  - ♻️ `refactor`: Code refactoring
  - ⚡️ `perf`: Performance improvements
  - ✅ `test`: Tests
  - 🔧 `chore`: Tooling, configuration
  - 🚀 `ci`: CI/CD improvements
  - 🗑️ `revert`: Reverting changes
  - 🧪 `test`: Add a failing test
  - 🚨 `fix`: Fix compiler/linter warnings
  - 🔒️ `fix`: Fix security issues
  - 👥 `chore`: Add or update contributors
  - 🚚 `refactor`: Move or rename resources
  - 🏗️ `refactor`: Make architectural changes
  - 🔀 `chore`: Merge branches
  - 📦️ `chore`: Add or update compiled files or packages
  - ➕ `chore`: Add a dependency
  - ➖ `chore`: Remove a dependency
  - 🌱 `chore`: Add or update seed files
  - 🧑‍💻 `chore`: Improve developer experience
  - 🧵 `feat`: Add or update code related to multithreading or concurrency
  - 🔍️ `feat`: Improve SEO
  - 🏷️ `feat`: Add or update types
  - 💬 `feat`: Add or update text and literals
  - 🌐 `feat`: Internationalization and localization
  - 👔 `feat`: Add or update business logic
  - 📱 `feat`: Work on responsive design
  - 🚸 `feat`: Improve user experience / usability
  - 🩹 `fix`: Simple fix for a non-critical issue
  - 🥅 `fix`: Catch errors
  - 👽️ `fix`: Update code due to external API changes
  - 🔥 `fix`: Remove code or files
  - 🎨 `style`: Improve structure/format of the code
  - 🚑️ `fix`: Critical hotfix
  - 🎉 `chore`: Begin a project
  - 🔖 `chore`: Release/Version tags
  - 🚧 `wip`: Work in progress
  - 💚 `fix`: Fix CI build
  - 📌 `chore`: Pin dependencies to specific versions
  - 👷 `ci`: Add or update CI build system
  - 📈 `feat`: Add or update analytics or tracking code
  - ✏️ `fix`: Fix typos
  - ⏪️ `revert`: Revert changes
  - 📄 `chore`: Add or update license
  - 💥 `feat`: Introduce breaking changes
  - 🍱 `assets`: Add or update assets
  - ♿️ `feat`: Improve accessibility
  - 💡 `docs`: Add or update comments in source code
  - 🗃️ `db`: Perform database related changes
  - 🔊 `feat`: Add or update logs
  - 🔇 `fix`: Remove logs
  - 🤡 `test`: Mock things
  - 🥚 `feat`: Add or update an easter egg
  - 🙈 `chore`: Add or update .gitignore file
  - 📸 `test`: Add or update snapshots
  - ⚗️ `experiment`: Perform experiments
  - 🚩 `feat`: Add, update, or remove feature flags
  - 💫 `ui`: Add or update animations and transitions
  - ⚰️ `refactor`: Remove dead code
  - 🦺 `feat`: Add or update code related to validation
  - ✈️ `feat`: Improve offline support

## Guidelines for Splitting Commits

When analyzing the diff, consider splitting commits based on these criteria:

1. **Different concerns**: Changes to unrelated parts of the codebase
2. **Different types of changes**: Mixing features, fixes, refactoring, etc.
3. **File patterns**: Changes to different types of files (e.g., source code vs documentation)
4. **Logical grouping**: Changes that would be easier to understand or review separately
5. **Size**: Very large changes that would be clearer if broken down

## Examples

Good commit messages:

- ✨ feat: add user authentication system
- 🐛 fix: resolve memory leak in rendering process
- 📝 docs: update API documentation with new endpoints
- ♻️ refactor: simplify error handling logic in parser
- 🚨 fix: resolve linter warnings in component files
- 🧑‍💻 chore: improve developer tooling setup process
- 👔 feat: implement business logic for transaction validation
- 🩹 fix: address minor styling inconsistency in header
- 🚑️ fix: patch critical security vulnerability in auth flow
- 🎨 style: reorganize component structure for better readability
- 🔥 fix: remove deprecated legacy code
- 🦺 feat: add input validation for user registration form
- 💚 fix: resolve failing CI pipeline tests
- 📈 feat: implement analytics tracking for user engagement
- 🔒️ fix: strengthen authentication password requirements
- ♿️ feat: improve form accessibility for screen readers

Example of splitting commits:

- First commit: ✨ feat: add new solc version type definitions
- Second commit: 📝 docs: update documentation for new solc versions
- Third commit: 🔧 chore: update package.json dependencies
- Fourth commit: 🏷️ feat: add type definitions for new API endpoints
- Fifth commit: 🧵 feat: improve concurrency handling in worker threads
- Sixth commit: 🚨 fix: resolve linting issues in new code
- Seventh commit: ✅ test: add unit tests for new solc version features
- Eighth commit: 🔒️ fix: update dependencies with security vulnerabilities

## Command Options

- `--no-verify`: Skip running the pre-commit hooks

## Environment Setup

The command automatically handles pre-commit environment setup:

1. **Cleans Terraform temporary files** (silently removes `.terraform`, `.terraform.lock.hcl`, `.terragrunt-cache` directories)
2. **Creates virtual environment** if `.venv` doesn't exist (using `uv venv`)
3. **Installs pre-commit** if not already installed (using `uv pip install pre-commit`)
4. **Installs pre-commit hooks** if not already installed (using `pre-commit install`)
5. **Only reports setup issues** if any of these steps fail
6. **Proceeds silently** if setup is successful

### Terraform Cleanup Command
```bash
find . -type d \( -name ".terraform" -o -name ".terragrunt-cache" \) -exec rm -rf {} +
find . -name ".terraform.lock.hcl" -delete
```
This prevents validation conflicts from stale Terraform state.

## Pre-commit Check Analysis

When pre-commit checks fail, the command will:

1. **Categorize failures** by type (formatting, security, validation, etc.)
2. **Provide specific recommendations** for each failing check
3. **Identify root causes** (e.g., missing dependencies, configuration issues)
4. **Suggest immediate fixes** where possible
5. **Stop the commit process** until issues are resolved

Common failure categories and solutions:

- **Terraform validation failures**: Usually require `terraform init` in affected directories
- **Formatting issues**: Can often be auto-fixed by re-running pre-commit
- **Security issues**: Require manual review and fixes
- **YAML/JSON syntax**: Need manual correction of syntax errors
- **Large files**: Remove or use Git LFS for large assets

## Important Notes

- **Pre-commit checks must pass before committing** - no exceptions unless using `--no-verify`
- The command will provide detailed analysis of any failing checks with actionable recommendations
- If specific files are already staged, the command will only commit those files
- If no files are staged, it will automatically stage all modified and new files
- The commit message will be constructed based on the changes detected
- Before committing, the command will review the diff to identify if multiple commits would be more appropriate
- If suggesting multiple commits, it will help you stage and commit the changes separately
- Always reviews the commit diff to ensure the message matches the changes
- Uses the git user configuration (name and email) from `.git/config` for commit authorship
