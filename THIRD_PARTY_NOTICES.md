# Third-party notices

The project MIT license applies to original project source. It does not relicense third-party services, SDK binaries, or trademarks.

| Component | Version / source | Treatment |
| --- | --- | --- |
| Agora macOS SDK | 4.6.2; six archives pinned in tools/dependencies.json | Downloaded from the vendor and excluded from Git; bundled in local applications. Binary SDK use and redistribution follow applicable Agora terms and component notices. |
| AgoraInfra macOS | 1.3.7; revision locked in Package.resolved | SwiftPM dependency, including aosl.framework. Preserve upstream notices. |
| rcodesign | 0.29.0; checksums in tools/fetch_signer.py | Build-time tool only; not included in the application. See upstream license. |
| Apple frameworks | macOS SDK | System dependencies, not redistributed by this repository. |
| OOPZ icon and notification sounds | Original AppIcon.icns and eight WAV files, unchanged from the existing native client; hashes in Resources/manifest.json | Official resources retained for this community client at the maintainer’s direction. Ownership remains with the original rights holders; these assets are excluded from the project MIT license. |
| OOPZ service | Official endpoints | External service and marks belong to their respective owners. No server software or production authentication material is included. |

Relevant upstream references:

- [Agora SDK package and pinned download checksums](https://github.com/AgoraIO/AgoraRtcEngine_macOS/tree/4.6.2)
- [Agora package wrapper license](https://github.com/AgoraIO/AgoraRtcEngine_macOS/blob/4.6.2/LICENSE)
- [AgoraInfra](https://github.com/AgoraIO/AgoraInfra_macOS/tree/1.3.7)
- [Agora terms](https://www.agora.io/en/terms-of-service/)
- [apple-platform-rs / rcodesign](https://github.com/indygreg/apple-platform-rs)

The SDK wrapper repository's MIT file alone is not a determination that every downloaded binary has the same license. The ffmpeg, fdk-aac and SoundTouch related binaries require review of the vendor's actual build notices before public binary distribution. This source migration does not certify that review as complete. Only the listed icon and notification sounds are committed as official resources. Original vendor application bundles, research captures and account data are excluded.

Artifact auditing recognizes five byte-identical vendor binaries by SHA-256 in tools/vendor_metadata.json. Their existing upstream attribution emails and build paths are not maintainer identity. Any changed binary loses this exception; credential checks and private denylist matches are never exempted. Development headers and module maps are omitted from assembled runtime frameworks.
