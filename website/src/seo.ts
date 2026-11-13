/**
 * Entity ids, shared copy and the landing JSON-LD graph (website brief §8.6). The ids have no
 * trailing slash and match independo.app's convention; the Organization stays a reference stub
 * because its full definition lives on independo.app.
 */
import { SITE } from "../docs-architecture.mjs";
import { LINKS } from "./site";

export const IDS = {
  organization: "https://www.independo.app#organization",
  website: `${SITE}#website`,
  software: `${SITE}#software`,
  webpage: `${SITE}#webpage`
} as const;

export const SOFTWARE_DESCRIPTION =
  "On-device AI for the devices your users actually have: one API for Capacitor, web, iOS and Android that keeps requests on the device when it can and uses a cloud only if allowed.";

export const LANDING = {
  title: "IndeRun — On-device AI for Capacitor with explicit fallback",
  description:
    "Run text tasks on Apple Foundation Models and Gemini Nano from one Capacitor API. Require on-device execution, or allow a cloud route you configure."
} as const;

export const IMPRINT = {
  title: "Imprint | IndeRun",
  description:
    "Imprint for inderun.dev: service provider and media owner Independo GmbH, Vienna, Austria, with registration, contact and supervisory details."
} as const;

export const PRIVACY = {
  title: "Privacy notice | IndeRun",
  description:
    "How inderun.dev processes personal data: Firebase Hosting, Google Analytics 4 with consent levels and Global Privacy Control, and your rights."
} as const;

export const NOTICES = {
  title: "Trademarks and licences | IndeRun",
  description:
    "Trademark notices for the third-party logos on inderun.dev, and the licences of its icons, font and the IndeRun SDK."
} as const;

/** Absolute URL of a site path: `/` is `https://inderun.dev/`, everything else has no trailing slash. */
export function absoluteUrl(sitePath: string): string {
  return sitePath === "/" ? `${SITE}/` : `${SITE}${sitePath.replace(/\/$/, "")}`;
}

export function landingGraph() {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Organization",
        "@id": IDS.organization,
        name: "Independo GmbH",
        url: "https://www.independo.app"
      },
      {
        "@type": "WebSite",
        "@id": IDS.website,
        url: SITE,
        name: "IndeRun",
        inLanguage: "en",
        license: LINKS.docsLicense,
        publisher: { "@id": IDS.organization }
      },
      {
        "@type": "SoftwareSourceCode",
        "@id": IDS.software,
        name: "IndeRun",
        description: SOFTWARE_DESCRIPTION,
        url: SITE,
        codeRepository: LINKS.repository,
        programmingLanguage: ["TypeScript", "Swift", "Kotlin", "Rust"],
        runtimePlatform: ["Capacitor", "iOS", "Android", "Web"],
        license: "https://opensource.org/licenses/MIT",
        author: { "@id": IDS.organization },
        maintainer: { "@id": IDS.organization },
        funder: { "@type": "Organization", name: "netidee", url: LINKS.netidee },
        sameAs: [
          LINKS.repository,
          LINKS.npmCapacitor,
          "https://www.npmjs.com/package/@independo/inderun-web"
        ]
      },
      {
        "@type": "WebPage",
        "@id": IDS.webpage,
        url: SITE,
        name: LANDING.title,
        inLanguage: "en",
        isPartOf: { "@id": IDS.website },
        about: { "@id": IDS.software }
      }
    ]
  };
}
