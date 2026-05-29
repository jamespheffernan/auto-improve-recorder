// Usage: node render.js <input.svg> <out.png> [size]
const fs = require('fs');
const { Resvg } = require('@resvg/resvg-js');

const [, , inPath, outPath, sizeArg] = process.argv;
const size = parseInt(sizeArg || '1024', 10);
const svg = fs.readFileSync(inPath, 'utf8');
const resvg = new Resvg(svg, {
  fitTo: { mode: 'width', value: size },
  background: 'rgba(0,0,0,0)',
});
const png = resvg.render().asPng();
fs.writeFileSync(outPath, png);
console.log(`rendered ${outPath} @ ${size}px`);
