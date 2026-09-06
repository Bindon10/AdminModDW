// CDWHoldTheBanner extends CDWPlantTheBanner, so this is a sibling of AdminModDWPTB rather
// than a subclass of it -- extending PTB here would drop HTB's own scoring and GRI.
class AdminModDWHTB extends CDWHoldTheBanner;

`include(AdminModDW/Include/AdminModDWHTB.uci)
`include(AdminModDW/Include/AdminModDWGame.uci)
