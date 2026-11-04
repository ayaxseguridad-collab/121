#!/usr/bin/env npx tsx
/**
 * upload-attachment.ts — Subir archivos como attachments a issues de Linear
 *
 * Linear usa Google Cloud Storage para attachments. El flow:
 *   1. Pides un signed URL al API de Linear (mutation fileUpload)
 *   2. Subes el archivo directo a GCS con HTTP PUT
 *   3. Vinculas el archivo a la issue con la mutation attachmentCreate
 *
 * Uso:
 *   import { uploadAttachment } from "./upload-attachment";
 *   await uploadAttachment({
 *     client,
 *     issueId: "TAL-42",
 *     file: { path: "./screenshot.png", contentType: "image/png" }
 *   });
 *
 * O via CLI:
 *   npx tsx upload-attachment.ts --action upload --issue TAL-42 --file ./screenshot.png
 *   npx tsx upload-attachment.ts --help
 *
 * --action es opcional para upload (default, retrocompatible con callers que solo pasan
 * --issue/--file sin --action).
 */

import * as fs from "fs";
import * as path from "path";
import { LinearMinClient, retryWithBackoff, loadApiKey } from "./linear-client";

interface UploadOptions {
  client: LinearMinClient;
  issueId: string;
  file: {
    path: string;
    contentType?: string;
  };
  /** Optional title for the attachment. Default: filename. */
  title?: string;
  /** Optional subtitle. */
  subtitle?: string;
}

const FILE_UPLOAD_MUTATION = `
  mutation FileUpload($size: Int!, $contentType: String!, $filename: String!) {
    fileUpload(size: $size, contentType: $contentType, filename: $filename) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        contentType
        filename
        size
        headers {
          key
          value
        }
      }
    }
  }
`;

const ATTACHMENT_CREATE_MUTATION = `
  mutation AttachmentCreate($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
`;

const ISSUE_BY_IDENTIFIER_QUERY = `
  query IssueByIdentifier($id: String!) {
    issue(id: $id) {
      id
      identifier
    }
  }
`;

const CONTENT_TYPE_BY_EXT: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".pdf": "application/pdf",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".json": "application/json",
  ".csv": "text/csv",
  ".log": "text/plain",
  ".mp4": "video/mp4",
  ".mov": "video/quicktime",
  ".zip": "application/zip",
};

function inferContentType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return CONTENT_TYPE_BY_EXT[ext] || "application/octet-stream";
}

/**
 * Sube un archivo y lo adjunta a una issue de Linear.
 */
export async function uploadAttachment(opts: UploadOptions): Promise<{
  attachmentId: string;
  attachmentUrl: string;
  assetUrl: string;
}> {
  const { client, issueId, file } = opts;

  // 1. Validar archivo
  if (!fs.existsSync(file.path)) {
    throw new Error(`File not found: ${file.path}`);
  }
  const stat = fs.statSync(file.path);
  if (stat.size === 0) throw new Error("File is empty");

  const contentType = file.contentType || inferContentType(file.path);
  const filename = path.basename(file.path);

  // 2. Resolver UUID si recibimos identifier
  let resolvedIssueId = issueId;
  if (/^[A-Z]+-\d+$/.test(issueId)) {
    const data = await client.query(ISSUE_BY_IDENTIFIER_QUERY, { id: issueId });
    if (!data.issue) throw new Error(`Issue not found: ${issueId}`);
    resolvedIssueId = data.issue.id;
  }

  // 3. Pedir signed URL
  console.log(`Requesting upload URL for ${filename} (${stat.size} bytes, ${contentType})...`);
  const uploadInfo = await client.query(FILE_UPLOAD_MUTATION, {
    size: stat.size,
    contentType,
    filename,
  });

  if (!uploadInfo.fileUpload?.success) throw new Error("fileUpload mutation returned success: false");
  const file_info = uploadInfo.fileUpload?.uploadFile;
  if (!file_info) throw new Error("Failed to get upload URL");

  // 4. Subir archivo a GCS
  console.log(`Uploading to ${maskUrl(file_info.uploadUrl)}...`);
  const fileBuffer = fs.readFileSync(file.path);

  const headers: Record<string, string> = {
    "Content-Type": contentType,
    "Content-Length": stat.size.toString(),
  };
  for (const h of file_info.headers || []) {
    headers[h.key] = h.value;
  }

  // PUT a una signed URL es idempotente (re-subir los mismos bytes no duplica nada en GCS) —
  // seguro para retryWithBackoff, a diferencia de una mutation GraphQL de creación. fetch() NO
  // lanza en respuestas HTTP de error (solo en fallos de red/timeout) — para que 429/5xx
  // también reintenten, la función envuelta debe LANZAR explícitamente en esos casos; un 4xx
  // "permanente" (403 signed URL expirada, etc.) NO se relanza, se deja pasar tal cual para que
  // el chequeo `!uploadResp.ok` de abajo lo reporte sin retries inútiles.
  class TransientUploadError extends Error {
    constructor(public status: number) {
      super(`GCS upload transient error: HTTP ${status}`);
    }
  }
  const uploadResp = await retryWithBackoff(
    async () => {
      const resp = await fetch(file_info.uploadUrl, {
        method: "PUT",
        headers,
        body: fileBuffer as any,
      });
      if (resp.status === 429 || resp.status >= 500) {
        throw new TransientUploadError(resp.status);
      }
      return resp;
    },
    { maxRetries: 3, baseDelayMs: 500 }
  );

  if (!uploadResp.ok) {
    const text = await uploadResp.text().catch(() => "");
    throw new Error(`GCS upload failed: ${uploadResp.status} ${uploadResp.statusText} ${text.slice(0, 200)}`);
  }

  console.log("Upload OK. Linking to issue...");

  // 5. Crear attachment vinculando el assetUrl a la issue
  const result = await client.query(ATTACHMENT_CREATE_MUTATION, {
    input: {
      issueId: resolvedIssueId,
      url: file_info.assetUrl,
      title: opts.title || filename,
      subtitle: opts.subtitle || `${(stat.size / 1024).toFixed(1)} KB`,
      iconUrl: iconForContentType(contentType),
      // metadata opcional para preservar info adicional
      metadata: {
        size: stat.size,
        filename,
        contentType,
      },
    },
  });

  if (!result.attachmentCreate.success) {
    throw new Error("Failed to create attachment");
  }

  return {
    attachmentId: result.attachmentCreate.attachment.id,
    attachmentUrl: result.attachmentCreate.attachment.url,
    assetUrl: file_info.assetUrl,
  };
}

/**
 * Linear solo soporta PNG/JPG para `iconUrl` via auth de API key (doc oficial de attachments,
 * verificado 2026-07-20) — no hay assets .svg públicos confirmados que cumplan ese contrato. Sin
 * un PNG/JPG oficial que apuntar, se omite `iconUrl` y se deja que Linear use su icono por defecto.
 */
function iconForContentType(_ct: string): string | undefined {
  return undefined;
}

function maskUrl(url: string): string {
  // Oculta query string sensible para logging
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}?...`;
  } catch {
    return "(invalid url)";
  }
}

// ====================================================================
// CLI
// ====================================================================

interface CLIArgs {
  help: boolean;
  action?: string;
  issue?: string;
  file?: string;
  title?: string;
  subtitle?: string;
}

function printHelp(): void {
  console.log(`Uso: npx tsx upload-attachment.ts [--action upload] --issue <TAL-X|UUID> --file <path> [opciones]

Acciones:
  upload (default)   Único action soportado — aplicado si se omite --action.

Opciones:
  --issue <TAL-X|UUID>   Requerido
  --file <path>          Requerido
  --title <str>          Opcional, default: nombre del archivo
  --subtitle <str>       Opcional
  --help, -h             Muestra esta ayuda y sale (no toca red ni LINEAR_API_KEY)`);
}

function parseArgs(argv: string[]): CLIArgs {
  const out: CLIArgs = { help: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--help" || arg === "-h") { out.help = true; }
    else if (arg === "--action") { out.action = next; i++; }
    else if (arg === "--issue") { out.issue = next; i++; }
    else if (arg === "--file") { out.file = next; i++; }
    else if (arg === "--title") { out.title = next; i++; }
    else if (arg === "--subtitle") { out.subtitle = next; i++; }
  }
  if (out.help) return out;
  if (out.action !== undefined && out.action !== "upload") {
    throw new Error(`action desconocida: "${out.action}" (solo se soporta "upload")`);
  }
  if (!out.issue || !out.file) {
    throw new Error("Required: --issue <TAL-X|UUID> --file <path>");
  }
  return out;
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }

  // Misma resolución que linear-client.ts: LINEAR_API_KEY > fichero de TA_OPERATION_ENV > .env.local de la raíz.
  let apiKey: string;
  try {
    apiKey = loadApiKey();
  } catch (err) {
    console.error(`Sin clave de Linear: ${(err as Error).message}`);
    process.exit(1);
  }

  const client = new LinearMinClient({ apiKey });

  uploadAttachment({
    client,
    issueId: args.issue!, // garantizado por parseArgs (throw si falta y !help)
    file: { path: args.file! },
    title: args.title,
    subtitle: args.subtitle,
  })
    .then((result) => {
      console.log("\n✅ Attached to issue.");
      console.log("   Asset URL:", result.assetUrl);
      console.log("   Attachment ID:", result.attachmentId);
    })
    .catch((err) => {
      console.error("Error:", err.message);
      process.exit(1);
    });
}
