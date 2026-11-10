# TerminalUIMaps test fixtures

Every fixture here is OpenStreetMap data, © OpenStreetMap contributors,
available under the [Open Database License (ODbL)
1.0](https://opendatacommons.org/licenses/odbl/1-0/). Each is kept unmodified,
as a produced work used to test this library; anything derived from it inherits
the ODbL's share-alike and attribution terms.

## `openfreemap-14-7812-6233.pbf.gz`

One vector tile, zoom 14, x 7812, y 6233 (Constância, Portugal, where the
Zêzere meets the Tejo), exactly as `tiles.openfreemap.org` served it on
2026-11-10 from the planet build `20261101_080013_pt`: gzip-compressed
(`Content-Encoding: gzip`), Mapbox Vector Tile 2.1 in the OpenMapTiles schema.

- Source URL:
  `https://tiles.openfreemap.org/planet/20261101_080013_pt/14/7812/6233.pbf`
- Size: 25 KB gzipped, 37 468 bytes inflated.
- Layers: boundary, building, housenumber, landcover, landuse, place, poi,
  transportation, transportation_name, water, water_name, waterway.

### Licence

The data is © OpenStreetMap contributors, available under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
The tile schema is OpenMapTiles' (© OpenMapTiles, CC-BY 4.0) and the tiles
are served by OpenFreeMap. The tile is kept here unmodified, as a produced
work used to test the decoder; anything derived from it inherits the ODbL's
share-alike and attribution terms.

## `openfreemap-14-8298-5636.pbf.gz`

One vector tile, zoom 14, x 8298, y 5636: central Paris, the Seine from the
Pont des Arts to the Pont Saint-Michel, the Louvre, Les Halles and
Saint-Germain-des-Prés — the densest kind of tile OpenFreeMap serves, and the
fixture the renderer's dense-city budget is measured on. Exactly as
`tiles.openfreemap.org` served it on 2026-11-10 from the planet build
`20261101_080013_pt`, named by the TileJSON at
`https://tiles.openfreemap.org/planet`: gzip-compressed
(`Content-Encoding: gzip`), Mapbox Vector Tile 2.1 in the OpenMapTiles schema.

- Source URL:
  `https://tiles.openfreemap.org/planet/20261101_080013_pt/14/8298/5636.pbf`
- Size: 684 KB gzipped, 1 183 588 bytes inflated.
- SHA-256 (as stored): `f1f7f67eefad6c123a367a6fe2ce234c64bf5c81a003854e3524da6498092abb`
- Layers: boundary, building (162 features), housenumber (395), landcover,
  landuse, park, place, poi (13 832, 9 697 named), transportation (1 689),
  transportation_name (646), water, water_name, waterway.
- A `poi` feature's id is the OpenStreetMap element's id times ten plus 1 for
  a node, 2 for a way and 3 for a relation, as planetiler writes it:
  14427318282 is way 1442731828, the Institut Arthur Vernes.

The tile schema is OpenMapTiles' (© OpenMapTiles, CC-BY 4.0) and the tiles are
served by OpenFreeMap.

## `nominatim-lookup-paris.json`

Nominatim's answer to
`https://nominatim.openstreetmap.org/lookup?osm_ids=N1528685379,W1442731828&format=jsonv2&extratags=1&namedetails=1&addressdetails=1`
on 2026-11-10: a restaurant (Le Paradis du fruit, hours past midnight,
wheelchair `limited`) and a clinic, both in the Paris tile above.

## `overpass-paris.json`

The Overpass API's answer (`https://overpass-api.de/api/interpreter`) on
2026-11-10 to
`[out:json][timeout:25];(node(id:1528685379,11240494238);way(1442731828););out tags center;`:
the restaurant and clinic above and a Franprix, with their tags.
