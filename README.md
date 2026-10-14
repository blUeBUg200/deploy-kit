# Installation Scripts

Automated, repeatable installation of data, observability and security platforms on Linux servers.

## The problem

Standing up these platforms by hand is slow and inconsistent. Steps are spread across vendor documentation, OS tuning is often skipped, offline environments need special handling, and two engineers rarely build the same server the same way. The result is deployments that are hard to reproduce, hard to troubleshoot and hard to scale.

## What this repository solves

Each project here turns a fresh server into a working, production-ready node with a single script run.

- **Faster deployments.** From a clean server to a running service in minutes, not hours.
- **Consistent results.** Every node is built the same way, in every environment.
- **Best practices built in.** Operating-system hardening and tuning are applied by default, not left as a follow-up task.
- **Works connected or air-gapped.** Supports both online and offline installation.
- **Safe to run again.** Handles existing or partial installations instead of failing on them.
- **Clear when something is wrong.** Checks the host first and explains exactly what is missing before making changes.
- **Scales out easily.** The same script builds the first node and every node after it.

## Who it is for

Engineers and consultants who deploy and operate these platforms for themselves or for customers, and want a reliable starting point instead of a manual checklist.

## Getting started

Each project lives in its own folder with its own README covering requirements, usage and limitations. Pick the project you need and follow its guide.

## Disclaimer

Provided as-is, without warranty. Review each script and test it in a non-production environment before use. Product names and trademarks belong to their respective owners; this repository is not affiliated with or endorsed by any vendor.

## License

See [LICENSE](LICENSE).
