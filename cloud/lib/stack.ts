import { Duration, RemovalPolicy, Stack, Tags } from 'aws-cdk-lib'
import type { StackProps } from 'aws-cdk-lib'
import { HttpApi, HttpMethod } from 'aws-cdk-lib/aws-apigatewayv2'
import { HttpJwtAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers'
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations'
import { PolicyStatement } from 'aws-cdk-lib/aws-iam'
import { Code, Function as LambdaFunction, Runtime } from 'aws-cdk-lib/aws-lambda'
import { UserPool, UserPoolClient } from 'aws-cdk-lib/aws-cognito'
import { Bucket } from 'aws-cdk-lib/aws-s3'
import type { Construct } from 'constructs'

// The stack declares no `env`, so it is environment-agnostic and every account and region it
// mentions is a CloudFormation pseudo-parameter rather than a value this machine resolved.
// ADR-0006 §8 lists the four things that would make claim 1 false — an `env`, a `fromLookup`,
// any bundling during synth, and a `cloud/cdk.context.json` — and each of them fails quietly,
// which is why `cloud/test/synth.test.ts` asserts against the sources and the template rather
// than against a deployment.

// The name the three handlers read the bucket out of. It is a constant here and a literal
// there, and nothing in this phase deploys, so no test can catch the two drifting apart by
// running them together — `testEveryHandlerFunctionIsHandedTheBucketUnderTheNameItsHandlerReads`
// reads the name out of `handlers/` and out of the synthesised template and compares them.
const BUCKET_VARIABLE = 'BUCKET'

// The asset directory `npm run build` writes, read by `Code.fromAsset` and never bundled
// during synth. `NodejsFunction` is refused for exactly this reason: it bundles at synth time
// with local esbuild when present and Docker when not, which makes the credential-free
// property a property of the machine rather than of the repository.
const HANDLER_ASSET = 'dist/handlers'

export class DunnageStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props)

    // No physical name: a globally unique bucket name committed to a repository is a
    // collision inherited by everyone who deploys it. The lifecycle rule is ADR-0006 §7 —
    // seven days is ADR-0005 O-10's exposure with a number on it, and it bounds an operation
    // nobody will complete rather than idle time.
    const bucket = new Bucket(this, 'Uploads', {
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      enforceSSL: true,
      lifecycleRules: [{ abortIncompleteMultipartUploadAfter: Duration.days(7) }],
    })

    // A user pool and an app client, and no identity pool. There is then no role a device
    // could assume, which is a stronger claim than a narrow one: the device holds a JWT and
    // no AWS credential at any point.
    const userPool = new UserPool(this, 'Users', { removalPolicy: RemovalPolicy.DESTROY })
    const userPoolClient = new UserPoolClient(this, 'Device', { userPool })

    const code = Code.fromAsset(HANDLER_ASSET)

    // An explicit statement rather than `bucket.grantPut()`. The grant helper expands to
    // aws-cdk-lib's BUCKET_PUT_ACTIONS, which includes `s3:Abort*`, and ADR-0006 §6 states
    // that `s3:AbortMultipartUpload` is granted to no role in this stack: no route aborts,
    // and a permission held for an operation that does not exist is the speculative kind the
    // architecture rules refuse. `s3:PutObject` is what `CreateMultipartUpload`, `UploadPart`
    // and `CompleteMultipartUpload` all require, and `s3:ListMultipartUploadParts` is the
    // enumeration permission the control plane keeps.
    //
    // A fresh statement per function rather than one object added to three roles: a policy
    // statement is mutable, and one shared instance makes three roles a single object three
    // constructs hold a reference to.
    const uploadsGrant = (): PolicyStatement =>
      new PolicyStatement({
        actions: ['s3:PutObject', 's3:ListMultipartUploadParts'],
        resources: [bucket.arnForObjects('uploads/*')],
      })

    const route = (id: string, entryPoint: string): LambdaFunction => {
      const fn = new LambdaFunction(this, `${id}Function`, {
        runtime: Runtime.NODEJS_24_X,
        handler: `${entryPoint}.handler`,
        code,
        environment: { [BUCKET_VARIABLE]: bucket.bucketName },
      })
      fn.addToRolePolicy(uploadsGrant())
      return fn
    }

    // The issuer is the user pool's own `ProviderURL` attribute, so it is a token this
    // template resolves at deploy time and not a region this machine wrote down. A literal
    // region here would make claim 1 false: the stack would name an environment.
    const authorizer = new HttpJwtAuthorizer('DeviceTokens', userPool.userPoolProviderUrl, {
      jwtAudience: [userPoolClient.userPoolClientId],
    })

    const api = new HttpApi(this, 'Api', { defaultAuthorizer: authorizer })

    // Three of ADR-0006 §4's four routes. `POST /uploads/{ref}/urls` arrives with
    // `handlers/urls.ts`, in the commit that writes it: a route with no handler is worse than
    // a route that is one commit late, and `Code.fromAsset` needs the asset directory to hold
    // what the template says it holds.
    api.addRoutes({
      path: '/uploads',
      methods: [HttpMethod.POST],
      integration: new HttpLambdaIntegration('CreateIntegration', route('Create', 'create')),
    })
    api.addRoutes({
      path: '/uploads/{ref}/parts',
      methods: [HttpMethod.GET],
      integration: new HttpLambdaIntegration('PartsIntegration', route('Parts', 'parts')),
    })
    api.addRoutes({
      path: '/uploads/{ref}/complete',
      methods: [HttpMethod.POST],
      integration: new HttpLambdaIntegration('CompleteIntegration', route('Complete', 'complete')),
    })

    // Applied at the stack rather than at the app. Every template assertion in this phase is
    // made against `Template.fromStack(new DunnageStack(new App(), 'Dunnage'))`, which builds
    // its own app and never runs `bin/dunnage.ts`, so a tag applied there would be absent
    // from every template a test reads.
    Tags.of(this).add('Project', 'Dunnage')
  }
}
