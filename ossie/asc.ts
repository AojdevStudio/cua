// App Store Connect API steps for ossie/ship-testflight.sh. Run with bun.
//
//   bun ossie/asc.ts check                  exit 3 when the app record is missing
//   bun ossie/asc.ts uploaded <build>       exit 0 when that build number is uploaded
//   bun ossie/asc.ts distribute <build>     wait for processing, then hand the
//                                           build to the internal group "Ossie"
//   bun ossie/asc.ts create-cert <csr.pem>  new Apple Distribution certificate, prints its id
//   bun ossie/asc.ts cert <id>              prints that certificate (base64 DER)
//   bun ossie/asc.ts distribution-certs     prints "<id> <base64 DER>" per distribution cert
//   bun ossie/asc.ts profile <cert-id>      prints the App Store profile (base64)
//
// The signing commands log to stderr, so the printed value can be captured.
//
// Reads APPLE_API_PRIVATE_KEY (.p8 PEM), APPLE_API_KEY_ID and
// APPLE_API_ISSUER_ID from the environment. Every step is a check-then-create,
// so a rerun converges instead of failing on what already exists.

const BUNDLE_ID = "studio.aoj.cuabots";
const GROUP_NAME = "Ossie";
// The team's Account Holder (Ossie), the one internal tester.
const TESTER_USER_ID = "9b50edc0-9faf-4090-beaa-6c4793d0f88d";
const API = "https://api.appstoreconnect.apple.com/v1";

type Resource<A> = { id: string; type: string; attributes: A };
type Page<A> = { data: Resource<A>[] };
type One<A> = { data: Resource<A> };
type AscError = { errors?: { status: string; code: string; title: string; detail?: string }[] };

class AscRequestError extends Error {
  constructor(readonly status: number, readonly body: AscError, method: string, path: string) {
    const first = body.errors?.[0];
    super(`${method} ${path} -> ${status} ${first?.code ?? ""}: ${first?.detail ?? first?.title ?? "no detail"}`);
  }
}

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set (ship-testflight.sh reads it from BWS with hush)`);
  return value;
}

const base64url = (bytes: Uint8Array | string) =>
  Buffer.from(bytes).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

async function token(): Promise<string> {
  const pem = env("APPLE_API_PRIVATE_KEY").replace(/\\n/g, "\n");
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env("APPLE_API_KEY_ID"), typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({ iss: env("APPLE_API_ISSUER_ID"), iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }),
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

async function asc<T>(method: "GET" | "POST" | "PATCH", path: string, body?: unknown): Promise<T | undefined> {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${await token()}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const json = text ? JSON.parse(text) : undefined;
  if (!response.ok) throw new AscRequestError(response.status, json ?? {}, method, path);
  return json as T | undefined;
}

async function get<T>(path: string): Promise<T> {
  const result = await asc<T>("GET", path);
  if (result === undefined) throw new Error(`GET ${path} returned no body`);
  return result;
}

async function findApp() {
  const apps = await get<Page<{ name: string; bundleId: string }>>(
    `/apps?filter[bundleId]=${BUNDLE_ID}&fields[apps]=name,bundleId`,
  );
  return apps.data.find((app) => app.attributes.bundleId === BUNDLE_ID);
}

type Build = { version: string; processingState: string; usesNonExemptEncryption: boolean | null };

async function waitForBuild(appId: string, buildNumber: string): Promise<Resource<Build>> {
  const deadline = Date.now() + 60 * 60 * 1000;
  let last = "";
  while (Date.now() < deadline) {
    const builds = await get<Page<Build>>(
      `/builds?filter[app]=${appId}&filter[version]=${buildNumber}&fields[builds]=version,processingState,usesNonExemptEncryption`,
    );
    const build = builds.data[0];
    const state = build?.attributes.processingState ?? "NOT_YET_VISIBLE";
    if (state !== last) console.log(`build ${buildNumber}: ${state}`);
    last = state;
    if (build && state === "VALID") return build;
    if (build && (state === "FAILED" || state === "INVALID")) {
      throw new Error(`build ${buildNumber} finished processing as ${state}; App Store Connect emails the reason`);
    }
    await Bun.sleep(30_000);
  }
  throw new Error(`build ${buildNumber} was not VALID after 60 minutes (last state ${last})`);
}

async function ensureCompliance(build: Resource<Build>) {
  if (build.attributes.usesNonExemptEncryption !== null) {
    console.log(`export compliance: already set (usesNonExemptEncryption=${build.attributes.usesNonExemptEncryption})`);
    return;
  }
  await asc("PATCH", `/builds/${build.id}`, {
    data: { type: "builds", id: build.id, attributes: { usesNonExemptEncryption: false } },
  });
  console.log("export compliance: set usesNonExemptEncryption=false");
}

type Group = { name: string; isInternalGroup: boolean; hasAccessToAllBuilds: boolean | null };

async function ensureGroup(appId: string): Promise<Resource<Group>> {
  const groups = await get<Page<Group>>(`/apps/${appId}/betaGroups?fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds`);
  const existing = groups.data.find((g) => g.attributes.name === GROUP_NAME && g.attributes.isInternalGroup);
  if (existing) {
    console.log(`beta group "${GROUP_NAME}": exists (${existing.id})`);
    return existing;
  }
  const created = await asc<One<Group>>("POST", "/betaGroups", {
    data: {
      type: "betaGroups",
      attributes: { name: GROUP_NAME, isInternalGroup: true, hasAccessToAllBuilds: true },
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
  });
  if (!created) throw new Error("POST /betaGroups returned no body");
  console.log(`beta group "${GROUP_NAME}": created (${created.data.id})`);
  return created.data;
}

// An internal tester is an App Store Connect user added to the group by the
// email on their user record.
async function ensureTester(group: Resource<Group>, appId: string) {
  const user = await get<One<{ username: string; firstName: string; lastName: string }>>(
    `/users/${TESTER_USER_ID}?fields[users]=username,firstName,lastName`,
  );
  const email = user.data.attributes.username;
  const members = await get<Page<{ email: string }>>(`/betaGroups/${group.id}/betaTesters?fields[betaTesters]=email&limit=200`);
  if (members.data.some((t) => t.attributes.email?.toLowerCase() === email.toLowerCase())) {
    console.log(`tester ${TESTER_USER_ID}: already in "${GROUP_NAME}"`);
    return;
  }
  const known = await get<Page<{ email: string }>>(
    `/betaTesters?filter[email]=${encodeURIComponent(email)}&filter[apps]=${appId}&fields[betaTesters]=email`,
  );
  const tester = known.data[0];
  if (tester) {
    await asc("POST", `/betaGroups/${group.id}/relationships/betaTesters`, {
      data: [{ type: "betaTesters", id: tester.id }],
    });
  } else {
    await asc("POST", "/betaTesters", {
      data: {
        type: "betaTesters",
        attributes: { email, firstName: user.data.attributes.firstName, lastName: user.data.attributes.lastName },
        relationships: { betaGroups: { data: [{ type: "betaGroups", id: group.id }] } },
      },
    });
  }
  console.log(`tester ${TESTER_USER_ID}: added to "${GROUP_NAME}"`);
}

async function attachBuild(group: Resource<Group>, build: Resource<Build>) {
  const attached = await get<Page<Build>>(`/betaGroups/${group.id}/builds?fields[builds]=version&limit=200`);
  if (attached.data.some((b) => b.id === build.id)) {
    console.log(`build ${build.attributes.version}: already in "${GROUP_NAME}"`);
    return;
  }
  try {
    await asc("POST", `/betaGroups/${group.id}/relationships/builds`, { data: [{ type: "builds", id: build.id }] });
    console.log(`build ${build.attributes.version}: attached to "${GROUP_NAME}"`);
  } catch (error) {
    // A group with access to all builds gets every build on its own, and
    // App Store Connect refuses an explicit add.
    if (error instanceof AscRequestError && error.status === 409 && group.attributes.hasAccessToAllBuilds) {
      console.log(`build ${build.attributes.version}: "${GROUP_NAME}" has access to all builds (${error.message})`);
      return;
    }
    throw error;
  }
}

// Signing. The API key has no access to cloud-managed certificates, so the
// app is signed with an Apple Distribution certificate this script created
// through the API. Its private key lives in BWS (CUABOTS_DISTRIBUTION_KEY).

type Certificate = { certificateType: string; certificateContent: string; expirationDate: string };

async function createCertificate(csrPath: string) {
  const csr = (await Bun.file(csrPath).text()).replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const created = await asc<One<Certificate>>("POST", "/certificates", {
    data: { type: "certificates", attributes: { certificateType: "DISTRIBUTION", csrContent: csr } },
  });
  if (!created) throw new Error("POST /certificates returned no body");
  console.error(`certificate: created Apple Distribution ${created.data.id}`);
  console.log(created.data.id);
}

// Every Apple Distribution certificate on the team, one "<id> <base64 DER>"
// line each, so a key can find its certificate.
async function distributionCertificates() {
  const certs = await get<Page<Certificate>>(
    "/certificates?filter[certificateType]=DISTRIBUTION&fields[certificates]=certificateContent&limit=200",
  );
  for (const cert of certs.data) console.log(`${cert.id} ${cert.attributes.certificateContent}`);
}

async function certificate(id: string) {
  const cert = await get<One<Certificate>>(`/certificates/${id}?fields[certificates]=certificateType,certificateContent,expirationDate`);
  console.error(`certificate: ${id} ${cert.data.attributes.certificateType}, expires ${cert.data.attributes.expirationDate}`);
  console.log(cert.data.attributes.certificateContent);
}

const PROFILE_NAME = "Cua Bots App Store";
type Profile = { name: string; profileState: string; profileType: string; profileContent: string };

async function bundleIdResource(): Promise<string> {
  const ids = await get<Page<{ identifier: string }>>(`/bundleIds?filter[identifier]=${BUNDLE_ID}&fields[bundleIds]=identifier`);
  const found = ids.data.find((b) => b.attributes.identifier === BUNDLE_ID);
  if (!found) throw new Error(`bundle id ${BUNDLE_ID} is not registered on the team`);
  return found.id;
}

// An App Store profile for the bundle id that holds this certificate, made
// once and reused while it stays active.
async function profile(certificateId: string) {
  const bundleId = await bundleIdResource();
  const fields = "fields[profiles]=name,profileState,profileType,profileContent";
  const profiles = await get<Page<Profile>>(`/bundleIds/${bundleId}/profiles?${fields}&limit=200`);
  for (const candidate of profiles.data) {
    const { name, profileState, profileType } = candidate.attributes;
    if (name !== PROFILE_NAME || profileType !== "IOS_APP_STORE" || profileState !== "ACTIVE") continue;
    const certs = await get<Page<object>>(`/profiles/${candidate.id}/certificates?fields[certificates]=certificateType`);
    if (certs.data.some((c) => c.id === certificateId)) {
      console.error(`profile: "${PROFILE_NAME}" exists (${candidate.id})`);
      console.log(candidate.attributes.profileContent);
      return;
    }
  }
  const created = await asc<One<Profile>>("POST", "/profiles", {
    data: {
      type: "profiles",
      attributes: { name: PROFILE_NAME, profileType: "IOS_APP_STORE" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundleId } },
        certificates: { data: [{ type: "certificates", id: certificateId }] },
      },
    },
  });
  if (!created) throw new Error("POST /profiles returned no body");
  console.error(`profile: created "${PROFILE_NAME}" (${created.data.id})`);
  console.log(created.data.attributes.profileContent);
}

async function main(argv: string[]) {
  const [command, arg] = argv;
  if (command === "create-cert" && arg) return createCertificate(arg);
  if (command === "cert" && arg) return certificate(arg);
  if (command === "distribution-certs") return distributionCertificates();
  if (command === "profile" && arg) return profile(arg);
  const buildNumber = arg;
  const app = await findApp();
  if (!app) {
    console.error(
      `No App Store Connect app record for ${BUNDLE_ID}.\n` +
        `Create it once at https://appstoreconnect.apple.com/apps (New App: iOS, name "Cua Bots", ` +
        `bundle ID ${BUNDLE_ID}, SKU cuabots), then rerun.`,
    );
    process.exit(3);
  }
  console.log(`app record: ${app.attributes.name} (${app.id})`);
  if (command === "check") return;
  if (command === "uploaded" && buildNumber) {
    const builds = await get<Page<Build>>(`/builds?filter[app]=${app.id}&filter[version]=${buildNumber}&fields[builds]=version`);
    process.exit(builds.data.length > 0 ? 0 : 1);
  }
  if (command !== "distribute" || !buildNumber) {
    console.error(
      "usage: bun ossie/asc.ts check | uploaded <build> | distribute <build> | create-cert <csr> | cert <id> | distribution-certs | profile <cert-id>",
    );
    process.exit(2);
  }
  const build = await waitForBuild(app.id, buildNumber);
  await ensureCompliance(build);
  const group = await ensureGroup(app.id);
  await ensureTester(group, app.id);
  await attachBuild(group, build);
  console.log(`done: build ${buildNumber} is in TestFlight group "${GROUP_NAME}"`);
}

await main(process.argv.slice(2));
