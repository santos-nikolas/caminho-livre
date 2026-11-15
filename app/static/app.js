const ROTULOS = { calcada_obstruida: "Calçada obstruída", rampa_bloqueada: "Rampa bloqueada", travessia_barreira: "Travessia com barreira" };
const CORES = { pendente: "#d9480f", em_analise: "#f59f00", resolvido: "#2b8a3e", descartado: "#868e96" };
const STATUS = Object.keys(CORES);
const $ = (id) => document.getElementById(id);
let ponto = null, marcador = null, camada = null, mapa = null, camadaPainel = null;
// traço diferente por nível, além da cor
const NIVEIS = {
  alta: { rotulo: "Atenção alta", cor: "#c92a2a", traco: null },
  media: { rotulo: "Atenção média", cor: "#b35c00", traco: "6 4" },
  baixa: { rotulo: "Atenção baixa", cor: "#2b8a3e", traco: "2 4" },
};

function descreverQuadra(c) {
  const demo = c.relatos_abertos_demonstracao ? ` (${c.relatos_abertos_demonstracao} de demonstração)` : "";
  return `Quadra ${c.id_celula} — ${NIVEIS[c.nivel_atencao].rotulo}: ${c.travessias} travessia(s), `
    + `${c.pontos_rebaixados} rebaixamento(s) mapeado(s), ${c.pontos_piso_tatil} ponto(s) com piso tátil, `
    + `${c.relatos_abertos} relato(s) aberto(s)${demo}.`;
}

async function carregarPainel() {
  const painel = await (await fetch("api/painel")).json();
  const quadras = painel.celulas.filter((c) => NIVEIS[c.nivel_atencao]);
  if (!quadras.length) { $("painel-resumo").textContent = "A situação por quadra ainda não foi publicada."; return; }
  const conta = (nivel) => quadras.filter((c) => c.nivel_atencao === nivel).length;
  $("painel-resumo").textContent = `${quadras.length} quadras avaliadas: ${conta("alta")} com atenção alta, `
    + `${conta("media")} com atenção média e ${conta("baixa")} com atenção baixa.`;
  $("painel-data").textContent = new Date(`${painel.data_referencia}T12:00:00`).toLocaleDateString("pt-BR");
  quadras.forEach((c) => {
    const n = NIVEIS[c.nivel_atencao];
    L.rectangle([[c.lat_min, c.lon_min], [c.lat_max, c.lon_max]],
      { color: n.cor, weight: 2, dashArray: n.traco, fillOpacity: c.nivel_atencao === "baixa" ? 0.08 : 0.25 })
      .bindTooltip(descreverQuadra(c), { sticky: true }).addTo(camadaPainel);
  });
  const ordem = { alta: 0, media: 1, baixa: 2 };
  const linhas = quadras.filter((c) => c.nivel_atencao !== "baixa")
    .sort((a, b) => ordem[a.nivel_atencao] - ordem[b.nivel_atencao] || b.relatos_abertos - a.relatos_abertos || b.travessias - a.travessias)
    .slice(0, 10)
    .map((c) => {
      const tr = document.createElement("tr");
      [c.id_celula, NIVEIS[c.nivel_atencao].rotulo, c.travessias, c.pontos_rebaixados, c.pontos_piso_tatil, c.relatos_abertos]
        .forEach((valor) => { tr.insertCell().textContent = valor; });
      return tr;
    });
  $("painel-tabela").tBodies[0].replaceChildren(...linhas);
  $("painel-tabela").hidden = !linhas.length;
}

function escolher(lat, lon) {
  ponto = { latitude: lat, longitude: lon };
  $("local").textContent = `${lat.toFixed(4)}, ${lon.toFixed(4)}`;
  if (marcador) marcador.remove();
  marcador = L.marker([lat, lon]).addTo(mapa);
}

function item(r) {
  const li = document.createElement("li");
  li.innerHTML = '<span class="tag demo">demonstração</span><span class="tag st"></span><strong></strong> <span class="meta"></span><p></p>';
  if (r.fonte !== "sintetico") li.querySelector(".demo").remove();
  li.querySelector(".st").textContent = r.status;
  li.querySelector("strong").textContent = ROTULOS[r.categoria];
  li.querySelector(".meta").textContent = new Date(r.criado_em).toLocaleString("pt-BR");
  li.querySelector("p").textContent = r.descricao_sanitizada || "";
  if ($("token").value) {
    const sel = document.createElement("select");
    sel.setAttribute("aria-label", "Alterar status");
    STATUS.forEach((s) => sel.add(new Option(s, s, false, s === r.status)));
    sel.onchange = () => revisar(r.id, sel.value);
    li.appendChild(sel);
  }
  return li;
}

async function carregar() {
  const dados = await (await fetch("api/reports")).json();
  $("atualizado").textContent = new Date(dados.atualizado_em).toLocaleString("pt-BR");
  camada.clearLayers();
  $("lista").replaceChildren(...dados.itens.map(item));
  dados.itens.forEach((r) =>
    L.circleMarker([r.latitude, r.longitude], { radius: 9, color: CORES[r.status], fillOpacity: 0.8 })
      .bindPopup(`${ROTULOS[r.categoria]} — ${r.status}`).addTo(camada));
}

async function revisar(id, status) {
  const r = await fetch(`api/admin/reports/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${$("token").value}` },
    body: JSON.stringify({ status }),
  });
  $("msg").textContent = r.ok ? "Status atualizado." : "Falha na revisão (token inválido?).";
  carregar();
}

$("form").onsubmit = async (e) => {
  e.preventDefault();
  if (!ponto) { $("msg").textContent = "Escolha o local no mapa primeiro."; return; }
  const r = await fetch("api/reports", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...ponto, categoria: $("categoria").value, descricao: $("descricao").value || null }),
  });
  const corpo = await r.json();
  $("msg").textContent = r.ok ? `Relato registrado com status "${corpo.status}".` : `Erro: ${corpo.detail}`;
  if (r.ok) { $("descricao").value = ""; carregar(); }
};

$("geo").onclick = () => navigator.geolocation.getCurrentPosition(
  (p) => escolher(p.coords.latitude, p.coords.longitude),
  () => { $("msg").textContent = "Não foi possível obter sua localização."; });
$("token").onchange = carregar;

(async () => {
  const cfg = await (await fetch("api/config")).json();
  const [minLat, minLon, maxLat, maxLon] = cfg.bbox;
  $("versao").textContent = cfg.version;
  mapa = L.map("mapa").fitBounds([[minLat, minLon], [maxLat, maxLon]]);
  L.tileLayer("https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png", {
    maxZoom: 19, attribution: "© OpenStreetMap · estilo HOT, servidor OSM France" }).addTo(mapa);
  L.rectangle([[minLat, minLon], [maxLat, maxLon]], { color: "#0b5cad", fill: false, dashArray: "4" }).addTo(mapa);
  camadaPainel = L.layerGroup().addTo(mapa);
  camada = L.layerGroup().addTo(mapa);
  $("ver-painel").onchange = (e) => (e.target.checked ? camadaPainel.addTo(mapa) : camadaPainel.remove());
  carregarPainel().catch(() => { $("painel-resumo").textContent = "Não foi possível carregar a situação por quadra."; });
  mapa.on("click", (e) => escolher(e.latlng.lat, e.latlng.lng));
  carregar();
})();
