# PngSuite images

The PNG images here are the subset of Willem van Schaik's PngSuite that
libpng ships in `contrib/pngsuite`: the fifteen `basn*.png` basic formats,
the fifteen `ft*.png` transparency images (two of them by Glenn
Randers-Pehrson), and two interlaced images, `ibasn0g08.png` and
`ibasn6a08.png`, which `erx_png` must refuse. Their license is in `README`,
copied unchanged: "Permission to use, copy, modify, and distribute these
images for any purpose and without fee is hereby granted."

* Source: libpng 1.6.50, `https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.50.tar.gz`,
  SHA-256 `71158e53cfdf2877bc99bcab33641d78df3f48e6e0daad030afe9cb8c031aa46`.
  The full PngSuite at `www.schaik.com` could not be fetched over HTTPS.
* Files: copied unchanged from `contrib/pngsuite`; `README` has SHA-256
  `0b8b3ace979daa00b182a3972e82523ec4701635add93a959422b9013c125439`.

`goldens.txt` is erXos's: for each non-interlaced image, its width, height
and the SHA-256 of its pixels as ImageMagick 7.1.2-34 (Q16-HDRI, Homebrew)
decodes them with `magick FILE -depth 8 rgba:-`, each colour then
premultiplied by its alpha as `(C * A + 127) div 255`, in R, G, B, A byte
order, which is `erx_png`'s output in the channel `a8b8g8r8`. ImageMagick
applies no gamma there and scales a 16-bit sample to 8 bits by rounding.
