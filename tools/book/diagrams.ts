// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause

// The book site's diagram driver (docs/design-book-site.md, "The diagram
// step"). esbuild bundles it with the imported beautiful-mermaid into one
// module, which Erx::Book::Diagrams runs under Node's permission model.
//
// Standard input is one JSON request, {"options": {...}, "diagrams":
// ["<source>", ...]}; standard output is one JSON reply, {"versions":
// {"node": "..."}, "results": [...]}, with one result per diagram in the
// same order: {"svg": "..."} or {"error": {"stage": "render", "message":
// "...", "line": null}}. A diagram that fails is a result, and the driver
// goes on; it exits non-zero only when the request itself is malformed.

import { renderMermaidSVG } from './beautiful-mermaid/index.ts'
import type { RenderOptions } from './beautiful-mermaid/index.ts'

type Request = { options: RenderOptions; diagrams: string[] }
type Result =
  | { svg: string }
  | { error: { stage: 'render'; message: string; line: number | null } }

// The request as the driver needs it, or an exception naming what is wrong.
function parseRequest(text: string): Request {
  const request: unknown = JSON.parse(text)
  if (typeof request !== 'object' || request === null || Array.isArray(request))
    throw new Error('the request is not a JSON object')
  const { options, diagrams } = request as Record<string, unknown>
  if (typeof options !== 'object' || options === null || Array.isArray(options))
    throw new Error('the request has no options object')
  if (!Array.isArray(diagrams) || !diagrams.every((source) => typeof source === 'string'))
    throw new Error('the request has no diagrams array of strings')
  return { options: options as RenderOptions, diagrams: diagrams as string[] }
}

function render(source: string, options: RenderOptions): Result {
  try {
    return { svg: renderMermaidSVG(source, options) }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return { error: { stage: 'render', message, line: null } }
  }
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = []
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer)
  return Buffer.concat(chunks).toString('utf8')
}

async function main(): Promise<void> {
  let request: Request
  try {
    request = parseRequest(await readStdin())
  } catch (error) {
    process.stderr.write(`diagrams: ${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 2
    return
  }
  const results = request.diagrams.map((source) => render(source, request.options))
  process.stdout.write(JSON.stringify({ versions: { node: process.versions.node }, results }))
}

await main()
