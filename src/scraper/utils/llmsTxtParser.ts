export interface LlmsTxtLink {
  title: string;
  url: string;
  description?: string;
  optional: boolean;
  section?: string;
}

export interface LlmsTxtSection {
  title: string;
  optional: boolean;
  links: LlmsTxtLink[];
}

export interface LlmsTxtResult {
  projectName?: string;
  summary?: string;
  sections: LlmsTxtSection[];
  links: LlmsTxtLink[];
}

const emptyLlmsTxtResult = (): LlmsTxtResult => ({
  sections: [],
  links: [],
});

const markdownLinkPattern = /^\s*[-*+]\s+\[([^\]\n]+)]\(([^)\s]+)\)\s*(?::\s*(.+?)\s*)?$/;

/**
 * Returns true when a URL points to an llms.txt meta-file.
 * @param url The URL to inspect.
 * @returns Whether the URL path basename is exactly llms.txt.
 */
export function isLlmsTxtUrl(url: string): boolean {
  try {
    const basename = new URL(url).pathname.split("/").filter(Boolean).at(-1);
    return basename?.toLowerCase() === "llms.txt";
  } catch {
    return false;
  }
}

/**
 * Parses llms.txt Markdown into project metadata and curated links.
 * @param content The llms.txt Markdown content.
 * @returns Parsed llms.txt metadata and links, or an empty result for invalid content.
 */
export function parseLlmsTxt(content: string): LlmsTxtResult {
  if (!content.trim() || content.includes("\0")) {
    return emptyLlmsTxtResult();
  }

  if (/^\s*<(?:!doctype\s+html|html|body|head)(?:\s|>)/i.test(content)) {
    return emptyLlmsTxtResult();
  }

  const lines = content.split(/\r?\n/);
  const firstH1Index = lines.findIndex((line) => /^#\s+\S/.test(line));

  // Standard llms.txt opens with an H1 title. Some sites (e.g. ai.google.dev) omit it,
  // using a bare title line followed by `## ` sections. Accept both: when there is no H1,
  // derive an optional project name from the first content line (if it isn't itself a
  // heading/list/quote) and parse from there. The link-count guard below still rejects
  // arbitrary prose, and HTML was already rejected above.
  let projectName: string | undefined;
  let startIndex: number;
  if (firstH1Index !== -1) {
    projectName = lines[firstH1Index].replace(/^#\s+/, "").trim();
    if (!projectName) {
      return emptyLlmsTxtResult();
    }
    startIndex = firstH1Index + 1;
  } else {
    const firstContentIndex = lines.findIndex((line) => line.trim() !== "");
    if (
      firstContentIndex !== -1 &&
      !/^\s*(?:#{1,6}\s|[-*+]\s|>)/.test(lines[firstContentIndex])
    ) {
      projectName = lines[firstContentIndex].trim();
      startIndex = firstContentIndex + 1;
    } else {
      startIndex = 0;
    }
  }

  const result: LlmsTxtResult = {
    ...(projectName ? { projectName } : {}),
    sections: [],
    links: [],
  };

  let currentSection: LlmsTxtSection | undefined;
  const summaryLines: string[] = [];
  let collectingSummary = true;

  for (const line of lines.slice(startIndex)) {
    if (/^#\s+\S/.test(line)) {
      collectingSummary = false;
      continue;
    }

    const h2Match = /^##\s+(.+?)\s*$/.exec(line);
    if (h2Match) {
      collectingSummary = false;
      const title = h2Match[1].trim();
      currentSection = {
        title,
        optional: title.toLowerCase() === "optional",
        links: [],
      };
      result.sections.push(currentSection);
      continue;
    }

    if (collectingSummary) {
      if (/^>\s?/.test(line)) {
        summaryLines.push(line.replace(/^>\s?/, "").trim());
        continue;
      }
      if (summaryLines.length > 0 && line.trim() === "") {
        continue;
      }
      if (line.trim() !== "") {
        collectingSummary = false;
      }
    }

    const linkMatch = markdownLinkPattern.exec(line);
    if (!linkMatch) {
      continue;
    }

    const link: LlmsTxtLink = {
      title: linkMatch[1].trim(),
      url: linkMatch[2].trim(),
      optional: currentSection?.optional ?? false,
      ...(currentSection ? { section: currentSection.title } : {}),
      ...(linkMatch[3]?.trim() ? { description: linkMatch[3].trim() } : {}),
    };

    currentSection?.links.push(link);
    result.links.push(link);
  }

  if (summaryLines.length > 0) {
    result.summary = summaryLines.join("\n");
  }

  if (result.links.length === 0) {
    return emptyLlmsTxtResult();
  }

  return result;
}
