# Source origin

Repository: https://github.com/lukilabs/beautiful-mermaid

Revision: 1.1.3

The `src/` directory and the `LICENSE` of the npm package
`beautiful-mermaid@1.1.3`, fetched once over HTTPS from
`https://registry.npmjs.org/beautiful-mermaid/-/beautiful-mermaid-1.1.3.tgz`.
The tarball's SHA-256 is
`4d436f27bb0102985940c3efe317153f4d1f53f20f029f226b60e1ab4b6b9ff0`, the
`archive_sha256` below; the registry's integrity hash for it is
`sha512-TItrtrAyHp1vwFfFVYauWGrquouk/6SS21Aq3RsxindSYZODcN4xYrPZD6BiZRU+o5mKJzDPz9MUSMvELdylyg==`.
`src/` is placed at the top of this directory, beside `LICENSE`, so
`index.ts` is the package's `src/index.ts`. License: MIT, Copyright (c)
2026 Craft Docs (`LICENSE`). Purpose: the book site's diagram step
renders the book's Mermaid diagrams to SVG with it
([docs/design-book-site.md](../../../docs/design-book-site.md), "The
import"). Status: `permanent`; see the dependency table in
`docs/design.md`.

The book draws flowcharts, state diagrams and sequence diagrams, so only
their renderers and the code they share are kept; the exclusions below
name what is left out. Its dependencies, elkjs and entities, are not in
the tree: `tools/book/pnpm-lock.yaml` pins them.

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/lukilabs/beautiful-mermaid",
  "revision": "1.1.3",
  "archive_sha256": "4d436f27bb0102985940c3efe317153f4d1f53f20f029f226b60e1ab4b6b9ff0",
  "exclusions": [
    {
      "path": "__tests__",
      "reason": "the library's tests, which run under Bun"
    },
    {
      "path": "ascii",
      "reason": "the ASCII renderer, not used by the book, which draws only flowcharts, state and sequence diagrams"
    },
    {
      "path": "browser.ts",
      "reason": "the browser entry, which the Node driver does not load"
    },
    {
      "path": "class",
      "reason": "the class diagram renderer, not used by the book, which draws only flowcharts, state and sequence diagrams"
    },
    {
      "path": "dist",
      "reason": "the built bundle; the build bundles src with esbuild instead"
    },
    {
      "path": "er",
      "reason": "the ER diagram renderer, not used by the book, which draws only flowcharts, state and sequence diagrams"
    },
    {
      "path": "package.json",
      "reason": "the package's manifest; tools/book/package.json pins its dependencies"
    },
    {
      "path": "README.md",
      "reason": "the package's README"
    },
    {
      "path": "xychart",
      "reason": "the XY chart renderer, not used by the book, which draws only flowcharts, state and sequence diagrams"
    }
  ],
  "removed": [],
  "files": {
    "LICENSE": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "f05f5a4009eae7fadfd4a55f77ffe10948f621982d56076667e68afbb54de894",
      "kind": "file",
      "non_ascii_lines": []
    },
    "elk-instance.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "b9dcdee434a53d6b14398321cc61d91002df87701c48326ae4ce79e2d4e5284e",
      "kind": "file",
      "non_ascii_lines": [
        "92627f7b0637adf8d3ed4179e14cb489de81153e215fb8b14557f83ac3888ae8",
        "a0ef4c125f2c54a966e6a728e34826474e608febc590c1aae01657b87340385d",
        "ed44239d84e95a96ff8c9f82345f5067ab03041278e208367edced9404e6c531",
        "72649a0bfddf7eb18b7e85ce2c22a589f0e29097f12da701cf6a08545b15bb1e",
        "63d753eac61ca60ffcedcc1667cde0b03878595f929430ae5a951b47ab62b0f5",
        "c54620f800527aa63dd17ca495999ada90f7e9ad570e1deeffe39d186285c9e7",
        "a1815c4937b6a40e415bf4158e99d6e51d7124818472cde80c22dad2209cb090"
      ]
    },
    "index.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "2ebaafc1f915a96cc5a996b50c2c68ee147b5b4b8ae066a4ec125e06d2d0c2aa",
      "kind": "file",
      "non_ascii_lines": [
        "b38c5428df2c7be6eea3d888907559cac56ca120f7c3cbe1133c7390fe112b39",
        "9fa68702f7b9c8e961ed19b7c5e995dff2dfe1cf4ed2086a39d7535f75acf816",
        "73d248adaf4d1dcaa072a5534be610c4b8e2b1dfd92a0c83f8072b933b32fb5a",
        "4822908cc34b1d2d875ec3b98cf92c296be165cb85f236ac798dd373247f18fe"
      ]
    },
    "layout-engine.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "7d6fee35536d1bace016630104baf1c175c6f16e67ab40fc064ebe9cb347b36c",
      "kind": "file",
      "non_ascii_lines": [
        "f7cc2b5ece37e635bc6cfde80c20619631f203c0cd4e67978d0d36ffa6c86bd0",
        "65dfd1a0d6ee6e284f9992ccb2389b29f556f69ccab5b72389e773fa51307635",
        "bc8f55ea2da124b9af35c2ed80c442e5bafaeadd39e304b989eba998380c8bfb",
        "9744d62f9ae0a0a3ea0a2cb3d58330d18dc284f7073fa1df62df145ab1a3d312",
        "a2898af8ee15edbda5c71b76e423fcaee18b43f5df1f4baf2db4c75e2c3b433a",
        "05bcb72e33ec0c789a4b1700aaa47f08e311359fa73f3ef96f69ab2d38aacee0",
        "3345d35d13ebbf11cc7fd196ee078350f1fadb60a4b3c6ec0adef05a311d3e29",
        "c4b52ad0eadf571efdbce5caba21c6cb19295f16b3a1668a9d5fb5aebc88d48b",
        "6012175e363a4faf09998252bef8d338e9f2173027ed3917505d82895c971235",
        "699368a7adecd9c8e110efc4b061f70b4c3bc5eec63cd0010fc74c9c181a28e7",
        "b51804ad18946fe54b76f2ae5d08bd72e55f422c9cce013a055bfdf0c3593a2b",
        "10a2296ed03adbb5bbc6c882f420f16e33249c17c00e9db834f9f2383b2b343e",
        "e4f15089644c1b07bc479f0ac4790eaf7831f57d5649bead457b2b8e3602ff14",
        "8abfd3e307dfd3a5f8f3c7549b26584fe0f9ac67c1c112105c0536b0f51f594a",
        "5eb0f65759d1e58cfa7f456fdb04b9c95a72b68b90982eb075d926ca9af65be2",
        "f78129a809f2cf6a31ecd93abc46c9173468c9cf9ea7ff6c159e267c6cd1a315",
        "fee830ea926dc4edbcfc0d08a519883cc6c27bc90f6cbdca289ad351e172529c"
      ]
    },
    "layout.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "ffccc9be26ce81338f9a19c208975e91c64f4b92830169d5d87707be2a12de31",
      "kind": "file",
      "non_ascii_lines": [
        "1de40d6b440fb6a22660c7a2d7974f10d309994062f02b21f889811c5690d77c"
      ]
    },
    "multiline-utils.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "a0c824701737d03cc5c300ca636a51577eea0f149390847bf662e43921a71c9f",
      "kind": "file",
      "non_ascii_lines": [
        "6e92d45292d58e64ae37a22eac1e2131168bb70419dfad081de525047cb5c180",
        "9d0d419e9b3f6fcb4b78100237d8f7d004fc7b238d8d8e9bf5f4eb42c02ad7c9",
        "c9ad6f1b1a655e42106374c34cb73a17d01e495a8e3b7e9706a0fbfd5de91b0f",
        "16dc9b465fcce5d3d9edb90528fd0ae4d2d1a725c488740fad741ba478f74331",
        "a0ca50094a4912c094678cc89adee1fdf21214fc76dbd7cc7e2bbe695bfea70a",
        "a2e0c8439e95e6a40b27d622c06b58322f2a1365774fdd290a4eedc81a3a64b3"
      ]
    },
    "parser.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "2bb573ab677425ba6d3e7fd802181f8e85a15c8ea9dc69cbcc436c2995d9e4b2",
      "kind": "file",
      "non_ascii_lines": [
        "d9162aeb0221287ac53a8cfca2f530a577777f2e3a14ac76ae7d0bda87953f01",
        "7037d023912364c6fc27c6edf14aa1503dd9909532bfdcd95b7a4a9204ab817f",
        "0c9727d97f52200d9582653732b57e62cde2a0ff35a7202c291d72d6a3a5ed34",
        "042fa4515830b4bf6dc9b7fb68ab3921bf93fa30d326a919b1ee2fc94bf304e4",
        "664b0f7e4a6eedbc7ceabab198a3030357fdd60bd9ad9cad3d255549e13131c0",
        "e7d4867ba267a75c55eb2615364eeb3eaccfc078a8429e6935804ac0a1bf4a19",
        "9776bb5a02f319773a6cdc7d6e94d2293712857ce6b10ce829de908629e1a8c4",
        "7c6910c7a8ce56e3d12cc6ac9a76426e43876450da4217ccc23ee0b25c44be1b",
        "fb3b2c957e3ee39a17a4f7575f44535afb93ed18743ba5564719a523c3e4bda2",
        "b64ee97703220ef3782515e46245c994696e4f3a348d500d69d3527dfaa9b668",
        "921dc01adfb24d0cf468383cafbceeedb007c3509d470ad96ebbb231ceb64f4b",
        "f3c20fcad3547a8a4f9ace8e4c9e21e71f4627dd5645d1d3bf0c761d0d47e98d",
        "be90fc7097da76334bb69c09673d734f9dae6d70ad48c06504506c68baae199f",
        "0df93d6988c6b04cb2eac78a312b1bd39618ec0e37aa8d0c85fc6b86166ffd5e"
      ]
    },
    "renderer.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "833bf92bc03981065d58a0a3dfe08063fcf3a752ea977aad4a6c891946364d55",
      "kind": "file",
      "non_ascii_lines": [
        "4d6711c462681e32a307f5d0685a5041bda6f53481f3b9b839e639498251ba87",
        "2505c7b640183b75050a52be59f37eab1496566308fa12e55f9259d00c4fa496",
        "75b9dc84f93086c2b64460bdf914ed23090412234e96228e86ab973e206f8ef1",
        "cd6e5aea88c0e29d6eef4b3778ba610ee86d6006742850cc9ca2bcf643f028e3",
        "0d1d0418220e9263785a74a4791ea554979779cc4105782af97b366fa22c068f",
        "90ea8ce409ac4ea4f8045cde27844383d28e562148a3e231ef6538a311bdb2a4",
        "d40c77ec96055bf5051a18cef4f93b6393a3b10e52596bc1bce0b0da7532f461",
        "5ca0929030e6ca999f311fe612c4fb785ac80476f0f21ab3565e3def3abf7de5",
        "fd70ced842c25bffd21c3e627b558fefb3fa37bb5bb615bfca69ff521aa868be",
        "72bfb5ecda5411127450ee33dd1b4b91b59d011534ae2b366439448f63768571",
        "795758429ec68aaa6c702ed54e370c38652886cf6b03d107965822f38fb7491c",
        "39e4d6da90ade3d56fd4bca798fa84d923a192e83c014f5493d602aef56cb0cc"
      ]
    },
    "sequence/layout.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "1ba9f7e0ba17eb54a2058e23c0e89b837405730d870b6298abc77a3e3708cb13",
      "kind": "file",
      "non_ascii_lines": [
        "8b2beac977bdd8ec6a678c888d78719a97c2197f52cce20d9e6c76e9bd2c0391",
        "e55faec4c1853841c5467dce3262f8ed0a1ef24628b98d031476b7b873b04abc",
        "eb393aebb3049cb5d7ebd3bfee19382309662653fcedc9707e0b72f6030d6b08",
        "c629b7c7b3c7ac60b527b90085625758e38c1d9fb3947be43ab9121dedcee4bb",
        "c9b1d4f091836c6ae762d02fef905aff24e14faa9423c93104afb972eed6fd63",
        "8dd1931535db83de012339e71383936a178dbe3b75c6a1f23870ee1b1c856397"
      ]
    },
    "sequence/parser.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "9958576a1d8463cdda0399cc249021b82dcb8a764aea1bf019300a102ea3b89d",
      "kind": "file",
      "non_ascii_lines": []
    },
    "sequence/renderer.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "725901bc536151dc54971fee6c063ae7224d6d332ef659b734e3dbca93d4c4b7",
      "kind": "file",
      "non_ascii_lines": [
        "d21133d5077a35fb29a9ec800206859ebc141040ff370a05b6a4f7c9d927db0f",
        "d9ad24f4ff15863d91075af1f5034798f81574529c06e8e7b96d05d0a2769894"
      ]
    },
    "sequence/types.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "97ffb68d504f4a2604c15a9941058071b3fee50b63a7d0aeb848db59b599b722",
      "kind": "file",
      "non_ascii_lines": [
        "bc085897baf3593013faeb4fdce915bb3a8cc94df425ca17f3864180b3b713f9",
        "3cffab50de1f3a7c6ec74e5ff95e127e44766f94f2bf2a0589231447ebdc0d4f"
      ]
    },
    "shape-clipping.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "7ed7471965891568d11d05d177269da7fbbab4a9bade764ba1a4e52476746541",
      "kind": "file",
      "non_ascii_lines": [
        "15bf31d1bb9dd6398d253d532c50d940aa7948bbfa82feadf40de44bc3f04d71",
        "daf9981d69cce7cfe16f38d396baf955021ab70e12cc3430b50c082d7c0b6034",
        "270b927e810e99561b6d6c283c08f8b210c490e0a908ceec4749a5be5eabc25e",
        "31c69c4d16a798a26ebfaee77224376d2baf924d74ab50d5499670442cbbc3e7",
        "507d250c6a1c517e8d819cca7a0b3349aff785f1c824e66e7ef6c2595f4815a4",
        "3acf4a90311d7d09b423fb2ec46df7fdeaeae1f204225f853c91813d02764570",
        "920277864a6c222e38b17348c1809f10136968fdc6e9f6ae356658a8f06e208f",
        "77f7143a28724a4531f77203eea1227fe13bb6ca7511ef3595e85bdc85c06d87"
      ]
    },
    "styles.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "334bfb80a58f9cb6242e3a145685bef3c6f112e4507e6c0f37ce81e18efb84fb",
      "kind": "file",
      "non_ascii_lines": [
        "a022e1f1891b8deda884e03778b9f1e93ebae2c409edf7c7f32a1dadc4bef6e8",
        "0bdaf56418e109bba3899d0b008111924808e508c8b8f3e855dd04d81088aab5",
        "2be39733676813a8fa41a8076e79898e076ebbd1cfa3768db522c52ce5c85dd7"
      ]
    },
    "text-metrics.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "840252c882b45742b938c7371e160086cc08e2a20226fc71654229713a0bc2d8",
      "kind": "file",
      "non_ascii_lines": [
        "f32a9a52928ea091ffe07fb4982fe201a4ff117836091c87e71b2c7a793f02ca",
        "904a41d68f532d881f5a712394be2d572262a039c207238d2cba6d4eda3b27f5",
        "e6788f5677ef63798b4cf5b77a8a929a8b6fb4bae03ede28e54195c2b8f8b18f",
        "c6c033ae6cae0c0a5ece5a1ccf226149444e635c1358d515f658aa88e3101bf0",
        "8d2e26bb4c5470f232e1f46bf6f2971b55673c32c935c3f212c1dbb1c62e1aac",
        "dffb9715d7b16cdd0f6efb4c65fdb319238d829e32ceab46aed89cd569096402",
        "04d893413c2f62abb1337238c8b67f5b3e67937045f394787774a89803a08a2a",
        "fadbe478b90caa0593aa25d0deab06259a5e72903fec0b4f13d1785177d65cd1",
        "dd207b2d680204df5602450b4e66e4683865921fa8ff9472c323c34875f980db",
        "b1c9e6d81f57b0d8c5344e5df259ebaa506f06c04db61665d3d3404bbacb4557",
        "cda1eb074c9196ad21b150da6acfe8f5f57a6aeccfd2113f897f1f1aa001cd13",
        "bca6b92aca9821988c5ca5d882af628d29b088ca5692a2871df1fb9c10b7ce95",
        "396580d171bd9898f442d59643244a0423234d5f3be21b27b65e4f47c443d374",
        "dad7db36b4b08e776e20f8f172d9da61847813c63d2ad65278cf0d302fabdc52",
        "596fff3a0f55a10a4f29b40587f3076043612877f96eb1ac26841bc85ec1ab98",
        "7563de70a525b52f02fc358a29fadfe67d1b747e10cc0e2166bbc414e06718f0",
        "2ee2df62ef63dde7b13a19821d0f4836fa0f6b9610ccc3fb1bd25146295a0ffb",
        "14749c0bb4de76466c4ee0067e423eef75c0e6cf28870904e86b9ac877b398b4",
        "b2675e712891891205222c0c9fcf8dd78768545b5607f7a69b71d3d1295a3450",
        "a3f356d37df7f5cb867c5f08dabd7e5b64dbb4573c2e8f782032ec3cb0fcffee",
        "8ff30a4bcc9bb5603d79f58632eb6285349ed8015c70ff788e79369c3f8e5048",
        "b245f40ddfbfddb2202ebf227d03d48a9e233465cb485fe07e35a54901f140f6",
        "8179e84a948da8eadad70b0b0014c5295061fb36166a6c7f0b27f37da94cfd4c",
        "01d654f3be84899a0b8c48ea4c2ac661b2ee5cbcfc03fd0853d290b2ebda0252",
        "faa6a48b327b52c5dec94d449c4d648b471a2f66bcf7183a4341285158d8257f",
        "17bde6bec286c628b7df9b052ac3a7719239b5b3cd622b1cfb9193e812ca8863"
      ]
    },
    "theme.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "42093ec6260e247384c8615de36f8079b3f0ddd7fd4d8bfca82d27fb94a73d18",
      "kind": "file",
      "non_ascii_lines": [
        "8d81f60b66860e8511021e7bf488823098a4f28ee3ecba5059247e3a21d712a4",
        "92b01f448aa3df404c115c20bdcbe34c3ac510d9354fa16aa88db7c5d9e1a8b7",
        "d0fec3c776144ef3ee13ad4547f1fc94da32b60ac3f89f836328786d71df14d5",
        "ae649f62a005febd6570bdba1df2c9376588505f9a7b7addb1ef9e41ea3e0ba2",
        "6c378736faf521d3534434ff7f263dfb89cf912c156dfe397f27a53b0fc9a137",
        "db899c958908dbef993c97f19cd5ccf624c8e5672a2bdf9288cdee1ec953835f",
        "fbc0000526373ea2d611f6be2c5eec24c001804e2efa3d14c68f4e32cc9ef653",
        "a2a460ccbcad8a06de930460ad0629066244d6a9fec641f09e0b8bde7b08daa0",
        "e8b80d2a0c0ffba87dbcd6c6cc06cc3ab85e276131605b556b115901623209dd",
        "473293fa5c4edda9cf2e12e564abecec71f19ac9f4e37e0eb8f3541c6ecdc691",
        "0ae6b409bc088f05ecdcb268e1c0c99f631519982099a9a043b278b3b99489d8",
        "75f273e12eee3f373def98a377465d582c15ca8328a22dc287383138ecc64aad",
        "b65339c60828c250b12e75b0efe26fe59659e8ecd68795f7b9c1895b7d1037f2",
        "3611fc54337fcbd8df9767f948ec3b8083d553b1dff0ddb0d1eb25ee326217f0",
        "94e470169e2743fb73ab042ac1fe5c999bf847f1335a0306caa89e16dc9c55dc",
        "e4380ebc240cb9758cdf6801bbce9c91e1ef6ae2f2c0c7991f19324fb7a70016",
        "1ad6fea401ee68bbc42d565656a52ef6fb1d08c2eb8b7bb4c4eff9fce6794642",
        "0253e7fc4cd1b008bae93ba835d9545edf462ee15e602cc76b62949da0e5193f"
      ]
    },
    "types.ts": {
      "license": "MIT",
      "evidence": "reviewed the package's LICENSE: the MIT License, copyright (c) 2026 Craft Docs; package.json declares MIT and its files carry no other notice",
      "reviewed": true,
      "sha256": "090ae3c96c9c77bfcbce0acbf1d8105ef2804515066c689d346be78630471b5d",
      "kind": "file",
      "non_ascii_lines": [
        "700e9d0fbd89adf47f12194393fba9d5e55b248387ee97eb91a3ff55047e5fe0",
        "2fdcb0a6839b1a2c7036dddfe1f29e7bb47e2f93a0b636802378ea5f27891af2",
        "ec48fa655b8f7d16f93b9f7331c747e53ee1673ed41dca12ee8c25fe11b29605",
        "dfea9448bb8bfee1606749dae2b6c5ac9a957d03dc2c3481d1017271612a3a5d",
        "e85624119a501f318ff470972a670ed984834440ee098715b494f6bdb3ebc8ee",
        "945360346557c064bd0a42c6325c14a7699bd83705685a2b66508e77e63ce505",
        "440eb2971ee5e432bdc5107ca99a2e7d1c4f17466af2778dd2934c6973fee5e7",
        "782ea462edbf38ef18918bfa32b50852499fd6ae6e4ec91426bdd81e9e31e4c9",
        "55c9a09e13b10b39226ae567b920ca34c604a9a69371cc4db09882cf13eda1b9",
        "3893df4c2deeb6abf0159d8cda5b803425688909b58f67bd9670cec4c9c3fa44",
        "c367258d7f51b718d14252b59099d6862dd54f4e34f62a7fde21aebdd2e07126",
        "d8fc2d818fa70fff6253d13ff14521c1313c43fbb51412037e9531db03bcb327",
        "4d24539c3699436991c1b2b96924881a8c81e45ba1792ca3050f473181bebf41",
        "b3d9554e29be908518b48eb5e1f4f1240f7ee2ef75b3c9e76cf723a563b9d72b",
        "247839bb0eec825988435d014deb6b2fccdd8ff17b05d2c8e504bdb950c7413b",
        "ae649f62a005febd6570bdba1df2c9376588505f9a7b7addb1ef9e41ea3e0ba2",
        "185e521489dda22fdc9bd62eeaee27d061ecbd51706a5a919f81306c357a9d89",
        "db899c958908dbef993c97f19cd5ccf624c8e5672a2bdf9288cdee1ec953835f",
        "fbc0000526373ea2d611f6be2c5eec24c001804e2efa3d14c68f4e32cc9ef653",
        "a2a460ccbcad8a06de930460ad0629066244d6a9fec641f09e0b8bde7b08daa0"
      ]
    }
  },
  "changes": {}
}
```
