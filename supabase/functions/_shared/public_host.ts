// Refuse to make requests to private / loopback / link-local / CGNAT
// addresses on behalf of a user-supplied URL (SSRF). Same rules as
// link-preview's guard.

export async function assertPublicHost(u: URL): Promise<void> {
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (/^(localhost|.*\.localhost|.*\.local|.*\.internal)$/i.test(host)) {
    throw new Error("blocked host");
  }
  const ips: string[] = [];
  if (isIp(host)) {
    ips.push(host);
  } else {
    for (const t of ["A", "AAAA"] as const) {
      try {
        ips.push(...await Deno.resolveDns(host, t));
      } catch { /* no record of that type */ }
    }
    if (ips.length === 0) throw new Error("host does not resolve");
  }
  for (const ip of ips) if (isPrivateIp(ip)) throw new Error("blocked address");
}

function isIp(s: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(s) || s.includes(":");
}

export function isPrivateIp(ip: string): boolean {
  if (ip.includes(":")) {
    const l = ip.toLowerCase();
    const mapped = l.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return isPrivateIp(mapped[1]);
    return l === "::1" || l === "::" ||
      /^f[cd][0-9a-f]{2}:/.test(l) ||
      /^fe[89ab][0-9a-f]:/.test(l);
  }
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => Number.isNaN(n) || n < 0 || n > 255)) {
    return true;
  }
  const [a, b] = p;
  return a === 0 || a === 10 || a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    a >= 224;
}
