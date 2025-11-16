# Copilot Instructions for Pull Request Review

This file guides code review behavior for GitHub Copilot when evaluating pull requests in this repository.

## Purpose

Provide consistent, helpful, and high‑quality automated feedback during pull request reviews.

## Review Guidelines

### 1. Code Quality

* Highlight duplicated logic, unnecessary complexity, or missing abstractions.
* Encourage clear, maintainable, and modular code.
* Suggest idiomatic patterns based on the language and framework used.

### 2. Documentation & Comments

* Flag missing or outdated documentation.
* Recommend concise comments where logic may be unclear.
* Encourage updates to README or related files if behavior changes.

### 3. Testing

* Check for missing unit, integration, or regression tests.
* Recommend test coverage for new features or bug fixes.
* Suggest improvements to test clarity or isolation.

### 4. Security & Reliability

* Identify insecure patterns, unsafe data handling, or missing validation.
* Recommend input sanitization or safer alternatives.
* Flag potential race conditions, resource leaks, or error‑handling gaps.

### 5. Performance

* Point out unnecessary computation or heavy operations.
* Suggest more efficient data structures or algorithms when appropriate.

### 6. Style & Consistency

* Enforce consistency with the existing project conventions.
* Flag formatting issues only if they differ from established style.

## Review Tone

* Keep suggestions constructive and specific.
* Avoid unrelated refactoring unless it directly improves the submitted changes.
* Prioritize clarity and usefulness over volume of comments.

## When to Approve

* All major quality, security, or correctness issues are addressed.
* Code aligns with project conventions and remains maintainable.
* Tests sufficiently cover new or changed behavior.

## When to Request Changes

* Critical logic issues, security risks, or regressions.
* Missing tests for key functionality.
* Major style or architectural inconsistencies.
