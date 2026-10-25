.pragma library

// The window's icons by name: Nerd Font glyphs from the Material Design
// range (nf-md-*), the same set the Omarchy shell draws its own icons from,
// so these verbs look like the desktop's. Outline variants where they exist.
// Codepoints checked against Nerd Fonts' glyphnames.json.

var GLYPHS = {
  logo: 0xF02EF,          // image-multiple-outline
  photos: 0xF02EF,        // image-multiple-outline
  explore: 0xF018C,       // compass-outline
  people: 0xF000F,        // account-multiple-outline
  person: 0xF0013,        // account-outline
  places: 0xF07D9,        // map-marker-outline
  albums: 0xF02EA,        // image-album
  shared: 0xF1514,        // share-variant-outline
  favorite: 0xF02D5,      // heart-outline
  favoriteOn: 0xF02D1,    // heart
  archive: 0xF120E,       // archive-outline
  unarchive: 0xF125C,     // archive-arrow-up-outline
  trash: 0xF0A7A,         // trash-can-outline
  deleteForever: 0xF0B89, // delete-forever-outline
  restore: 0xF099B,       // restore
  tags: 0xF12F7,          // tag-multiple-outline
  tag: 0xF04FC,           // tag-outline
  folders: 0xF0255,       // folder-multiple-outline
  folder: 0xF0256,        // folder-outline
  sync: 0xF04E6,          // sync
  cloudSync: 0xF12D6,     // cloud-sync-outline
  cloudCheck: 0xF12CC,    // cloud-check-outline
  cloudOff: 0xF0164,      // cloud-off-outline
  cloudUpload: 0xF0B7E,   // cloud-upload-outline
  upload: 0xF0552,        // upload
  download: 0xF0B8F,      // download-outline
  settings: 0xF08BB,      // cog-outline
  search: 0xF0349,        // magnify
  refresh: 0xF0450,       // refresh
  menu: 0xF035C,          // menu
  more: 0xF01D9,          // dots-vertical
  close: 0xF0156,         // close
  back: 0xF004D,          // arrow-left
  forward: 0xF0054,       // arrow-right
  chevronLeft: 0xF0141,   // chevron-left
  chevronRight: 0xF0142,  // chevron-right
  chevronDown: 0xF0140,   // chevron-down
  plus: 0xF0415,          // plus
  check: 0xF012C,         // check
  checkCircle: 0xF05E0,   // check-circle
  circle: 0xF0766,        // circle-outline
  info: 0xF02FD,          // information-outline
  play: 0xF040A,          // play
  pause: 0xF03E4,         // pause
  video: 0xF0BDC,         // video-outline
  live: 0xF1591,          // motion-play-outline
  link: 0xF0339,          // link-variant
  copy: 0xF018F,          // content-copy
  edit: 0xF0CB6,          // pencil-outline
  calendar: 0xF0B66,      // calendar-blank-outline
  camera: 0xF0D5D,        // camera-outline
  image: 0xF0976,         // image-outline
  zoomIn: 0xF06ED,        // magnify-plus-outline
  zoomOut: 0xF06EC,       // magnify-minus-outline
  fullscreen: 0xF0293,    // fullscreen
  sidebar: 0xF10AA,       // dock-left
  warning: 0xF002A,       // alert-outline
  error: 0xF05D6,         // alert-circle-outline
  pauseCircle: 0xF03E6,   // pause-circle-outline
  playCircle: 0xF040D,    // play-circle-outline
  eye: 0xF06D0,           // eye-outline
  eyeOff: 0xF06D1,        // eye-off-outline
  star: 0xF04D2,          // star-outline
  starOn: 0xF04CE,        // star
  map: 0xF0982,           // map-outline
  key: 0xF030B,           // key-variant
  server: 0xF048B,        // server
  merge: 0xF00F8,         // call-merge
  cake: 0xF00EB,          // cake-variant
  open: 0xF03CC,          // open-in-new
  stack: 0xF09FE,         // layers-outline
  partner: 0xF0BE3,       // account-heart-outline
  select: 0xF0139,        // checkbox-multiple-marked-outline
  slideshow: 0xF13E6,     // play-box-multiple-outline
  grid: 0xF11D9,          // view-grid-outline
  text: 0xF09ED,          // text-box-outline
  help: 0xF0625,          // help-circle-outline
  sort: 0xF04BF,          // sort-variant
  filter: 0xF0233,        // filter-outline
  personSearch: 0xF0935,  // account-search-outline
  computer: 0xF0322,      // laptop
  dates: 0xF0B68,         // calendar-range-outline
  lens: 0xF0104,          // camera-iris
  fileUpload: 0xF0A4E,    // file-upload-outline
  chevronUp: 0xF0143,     // chevron-up
  moreHorizontal: 0xF01D8, // dots-horizontal
  noImage: 0xF11D1,       // image-off-outline
  minus: 0xF0374          // minus
}

function glyph(name) {
  var code = GLYPHS[name]
  if (code === undefined) return ""
  return String.fromCodePoint(code)
}
