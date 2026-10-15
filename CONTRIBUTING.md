# Contributing to Google Ruby Core Libraries

1. **Sign one of the contributor license agreements below.**
2. Fork the repo, develop and test your code changes.
3. Send a pull request.

## Contributor License Agreements

Before we can accept your pull requests you'll need to sign a Contributor License Agreement (CLA):

- **If you are an individual writing original source code** and **you own the intellectual property**, then you'll need to sign an [individual CLA](https://developers.google.com/open-source/cla/individual).
- **If you work for a company that wants to allow you to contribute your work**, then you'll need to sign a [corporate CLA](https://developers.google.com/open-source/cla/corporate).

You can sign these electronically (just scroll to the bottom). After that, we'll be able to accept your pull requests.

## Working with the code

### Tests

Tests are very important part of ruby-core-libraries. All contributions should include tests that ensure the contributed code behaves as expected.

#### Setup

In order to run the project's tests, there is a small amount of setup:

1. Install Ruby.
    ruby-core-libraries requires Ruby 3.0+. You may choose to manage your Ruby and gem installations with [rbenv](https://github.com/rbenv/rbenv), [chruby](https://github.com/postmodern/chruby), or [asdf](https://asdf-vm.com/)

2. Install the dependencies of the package you are working on. The test tasks are written using [Rake](https://github.com/ruby/rake), which is part of each package's bundle.

    ```sh
    $ cd <package-name>
    $ bundle install
    ```

#### Unit Tests

The project uses the [minitest](https://github.com/seattlerb/minitest) library for tests.

To run the unit tests for a package:

``` sh
$ cd <package-name>
$ bundle exec rake test
```

Or, from the root directory of the repository:

``` sh
$ bin/ci --gems=<package-name> --test
```

New code contributions should come with unit tests. Generally we prefer unit tests use spec-style `describe` and `it` blocks, but use assertions rather than spec-style expectations.

#### Code style

Please follow the established coding style in the library. The style is defined in the [google-style](https://github.com/googleapis/ruby-style) gem, and is largely based on [The Ruby Style Guide](https://github.com/bbatsov/ruby-style-guide) with a few exceptions based on seattle-style:

* Avoid parenthesis when possible, including in method definitions.
* Always use double quotes strings. ([Option B](https://github.com/bbatsov/ruby-style-guide#strings))

You can check your code against these rules by running Rubocop like so:

```sh
$ cd <package-name>
$ bundle exec rake rubocop
```

Or, from the root directory of the repository:

``` sh
$ bin/ci --gems=<package-name> --rubocop
```

#### Documentation Tests

The project uses [Yard](https://yardoc.org/) to generate documentation. Generally we require full documentation coverage of all elements. Documentation testing ensures that Yardocs always build without warnings.

To run the documentation tests for a package:

``` sh
$ cd <package-name>
$ bundle exec rake yardoc
```

Or, from the root directory of the repository:

``` sh
$ bin/ci --gems=<package-name> --yard
```

#### Running all tests

To run all checks for all packages in this repo, including unit tests, code style checks, and build and documentation tests:

``` sh
$ bin/ci --all-gems --all-tasks
```

To run all checks for a single gem:

``` sh
$ bin/ci --gems=<package-name> --all-tasks
```

For more information:

``` sh
$ bin/ci --help
```

## Code of Conduct

Please note that this project is released with a Contributor Code of Conduct. By participating in this project you agree to abide by its terms. See [Code of Conduct](CODE_OF_CONDUCT.md) for more information.

## Code reviews

All submissions, including submissions by project members, require review. We
use GitHub pull requests for this purpose. Consult
[GitHub Help](https://help.github.com/articles/about-pull-requests/) for more
information on using pull requests.

## Community Guidelines

This project follows [Google's Open Source Community
Guidelines](https://opensource.google.com/conduct/).
