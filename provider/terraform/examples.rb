# Copyright 2017 Google Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'uri'
require 'api/object'
require 'compile/core'
require 'google/golang_utils'
require 'provider/abstract_core'

module Provider
  class Terraform < Provider::AbstractCore
    # Generates configs to be shown as examples in docs and outputted as tests
    # from a shared template
    class Examples < Api::Object
      include Compile::Core
      include Google::GolangUtils

      # The name of the example in lower snake_case.
      # Generally takes the form of the resource name followed by some detail
      # about the specific test. For example, "address_with_subnetwork".
      attr_reader :name

      # The id of the "primary" resource in an example. Used in import tests.
      # This is the value that will appear in the Terraform config url. For
      # example:
      # resource "google_compute_address" {{primary_resource_id}} {
      #   ...
      # }
      attr_reader :primary_resource_id

      # vars is a Hash from template variable names to output variable names.
      # It will use the provided value as a prefix for generated tests, and
      # insert it into the docs verbatim.
      attr_reader :vars

      # Some variables need to hold special values during tests, and cannot
      # be inferred by Open in Cloud Shell.  For instance, org_id
      # needs to be the correct value during integration tests, or else
      # org tests cannot pass. Other examples include an existing project_id,
      # a zone, a service account name, etc.
      #
      # test_env_vars is a Hash from template variable names to one of the
      # following symbols:
      #  - :PROJECT_NAME
      #  - :FIRESTORE_PROJECT_NAME
      #  - :CREDENTIALS
      #  - :REGION
      #  - :ORG_ID
      #  - :ORG_TARGET
      #  - :BILLING_ACCT
      #  - :SERVICE_ACCT
      # This list corresponds to the `get*FromEnv` methods in provider_test.go.
      attr_reader :test_env_vars

      # Hash to provider custom context for generating test config
      attr_reader :test_custom_context

      # The version name of of the example's version if it's different than the
      # resource version, eg. `beta`
      #
      # This should be the highest version of all the features used in the
      # example; if there's a single beta field in an example, the example's
      # min_version is beta. This is only needed if an example uses features
      # with a different version than the resource; a beta resource's examples
      # are all automatically versioned at beta.
      #
      # When an example has a version of beta, each resource must use the
      # `google-beta` provider in the config. If the `google` provider is
      # implicitly used, the test will fail.
      #
      # NOTE: Until Terraform 0.12 is released and is used in the OiCS tests, an
      # explicit provider block should be defined. While the tests @ 0.12 will
      # use `google-beta` automatically, past Terraform versions required an
      # explicit block.
      attr_reader :min_version

      # Extra properties to ignore read on during import.
      # These properties will likely be custom code.
      attr_reader :ignore_read_extra

      # Whether to skip generating tests for this resource
      attr_reader :skip_test

      # The name of the primary resource for use in IAM tests. IAM tests need
      # a reference to the primary resource to create IAM policies for
      attr_reader :primary_resource_name

      # The path to this example's Terraform config.
      # Defaults to `templates/terraform/examples/{{name}}.tf.erb`
      attr_reader :config_path

      def config_documentation
        docs_defaults = {
          PROJECT_NAME: 'my-project-name',
          FIRESTORE_PROJECT_NAME: 'my-project-name',
          CREDENTIALS: 'my/credentials/filename.json',
          REGION: 'us-west1',
          ORG_ID: '123456789',
          ORG_TARGET: '123456789',
          BILLING_ACCT: '000000-0000000-0000000-000000',
          SERVICE_ACCT: 'emailAddress:my@service-account.com'
        }
        @vars ||= {}
        @test_env_vars ||= {}
        body = lines(compile_file(
                       {
                         vars: vars,
                         test_env_vars: test_env_vars.map { |k, v| [k, docs_defaults[v]] }.to_h,
                         primary_resource_id: primary_resource_id
                       },
                       config_path
                     ))
        lines(compile_file(
                { content: body },
                'templates/terraform/examples/base_configs/documentation.tf.erb'
              ))
      end

      def config_test
        body = config_test_body
        lines(compile_file(
                {
                  content: body
                },
                'templates/terraform/examples/base_configs/test_body.go.erb'
              ))
      end

      # rubocop:disable Style/FormatStringToken
      def config_test_body
        @vars ||= {}
        @test_env_vars ||= {}
        body = lines(compile_file(
                       {
                         vars: vars.map { |k, str| [k, "#{str}%{random_suffix}"] }.to_h,
                         test_env_vars: test_env_vars.map { |k, _| [k, "%{#{k}}"] }.to_h,
                         primary_resource_id: primary_resource_id
                       },
                       config_path
                     ))

        substitute_test_paths body
      end

      def config_example
        @vars ||= []
        # Examples with test_env_vars are skipped elsewhere
        body = lines(compile_file(
                       {
                         vars: vars.map { |k, str| [k, "#{str}-${local.name_suffix}"] }.to_h,
                         primary_resource_id: primary_resource_id
                       },
                       config_path
                     ))

        substitute_example_paths body
      end

      def oics_link
        hash = {
          cloudshell_git_repo: 'https://github.com/terraform-google-modules/docs-examples.git',
          cloudshell_working_dir: @name,
          cloudshell_image: 'gcr.io/graphite-cloud-shell-images/terraform:latest',
          open_in_editor: 'main.tf',
          cloudshell_print: './motd',
          cloudshell_tutorial: './tutorial.md'
        }
        URI::HTTPS.build(
          host: 'console.cloud.google.com',
          path: '/cloudshell/open',
          query: URI.encode_www_form(hash)
        )
      end

      # rubocop:disable Metrics/LineLength
      def substitute_test_paths(config)
        config.gsub!('../static/img/header-logo.png', 'test-fixtures/header-logo.png')
        config.gsub!('path/to/private.key', 'test-fixtures/ssl_cert/test.key')
        config.gsub!('path/to/certificate.crt', 'test-fixtures/ssl_cert/test.crt')
        config.gsub!('path/to/index.zip', '%{zip_path}')
        config.gsub!('verified-domain.com', 'tf-test-domain%{random_suffix}.gcp.tfacc.hashicorptest.com')
        config
      end

      def substitute_example_paths(config)
        config.gsub!('../static/img/header-logo.png', '../static/header-logo.png')
        config.gsub!('path/to/private.key', '../static/ssl_cert/test.key')
        config.gsub!('path/to/certificate.crt', '../static/ssl_cert/test.crt')
        config
      end
      # rubocop:enable Metrics/LineLength
      # rubocop:enable Style/FormatStringToken

      def validate
        super
        check :name, type: String, required: true
        check :primary_resource_id, type: String
        check :min_version, type: String
        check :vars, type: Hash
        check :test_env_vars, type: Hash
        check :test_config_context, type: Hash
        check :ignore_read_extra, type: Array, item_type: String, default: []
        check :primary_resource_name, type: String
        check :skip_test, type: TrueClass
        check :config_path, type: String, default: "templates/terraform/examples/#{name}.tf.erb"
      end
    end
  end
end
