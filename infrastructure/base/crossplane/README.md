# Crossplane Configuration

## Writing and Pushing Functions

We have chosen [KCL (Kusion Configuration Language)](https://github.com/crossplane-contrib/function-kcl) to write most of the logic in our Crossplane compositions. These functions are packaged as OCI artifacts. For this repository, we use ephemeral OCI registries because we frequently destroy and recreate the platform. However, for production environments, more persistent solutions should be considered.

Here is an example for creating and pushing a composition for an RDS instance:

```console
cd infrastructure/base/crossplane/configuration/kcl
kcl mod init rdsinstance
```

After writing the code, we can render the output directly from the module directory using the command

```console
cd rdsinstance
kcl run -Y settings-example.yam
```

Then you can push it to an OCI registry as follows:

```console
cd rdsinstance
kcl mod push oci://ttl.sh/ogenki-cnref/rdsinstance:v0.0.1-24h
```

Here we're using [TTL.sh](https://ttl.sh/) and the OCI artifact will be available for 24 hours, as specified in the tag. You can then reference it in your Crossplane composition:

```yaml
...
spec:
...
    pipeline:
...
        - step: rds
          functionRef:
              name: function-kcl
          input:
              apiVersion: krm.kcl.dev/v1alpha1
              kind: KCLRun
              spec:
                  target: Resources
                  source: oci://ttl.sh/ogenki-cnref/rdsinstance:v0.0.1-24h
```

## Validating a composition

To validate a composition, such as `sqlinstance`, you can use Crossplane's `render` command with example inputs. Navigate to the Crossplane configuration directory and run the following command:

```console
cd infrastructure/base/crossplane/configuration
crossplane render --extra-resources examples/environmentconfig.yaml examples/sqlinstance.yaml sql-instance-composition.yaml functions.yaml
```

This will render and validate the composition based on the provided example configurations.
