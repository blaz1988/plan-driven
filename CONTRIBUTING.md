# Contributing

Thanks for taking the time to improve `plan_driven`.

## Reporting a bug

Open an issue at <https://github.com/blaz1988/plan-driven/issues> with:

- the Ruby, Rails and gem versions, and the LLM provider and model you use;
- the command you ran, what you expected and what happened;
- the output of `bundle exec plan-driven doctor`.

Please leave out API keys and anything from your plans you wouldn't post publicly. For a
security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Making a change

```bash
git clone git@github.com:blaz1988/plan-driven.git
cd plan-driven
bin/setup
bundle exec rake    # specs and RuboCop
```

1. Fork the repository and create a branch from `main`.
2. Add a spec for the change. Guard specs are table-driven, so a new rule is often a few lines.
3. Run `bundle exec rake`. If the change touches the models, the generator or schema
   introspection, run `bin/matrix` as well, which covers every supported Ruby and Rails
   combination.
4. Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
5. Open a pull request that explains what changed and why.

## A note on the approach

When the model keeps getting something wrong, fix it in a guard or the normalizer rather than
adding another line to a prompt. A rule in code is checked every time, can be tested, and is
reported to the user; a prompt line is a suggestion. Pull requests in that spirit are
especially welcome.

## Code of conduct

Be kind and assume good intent. Harassment or abuse of any kind isn't tolerated in issues,
pull requests or any other project space.
