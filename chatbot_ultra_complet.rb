# encoding: utf-8
require 'webrick'
require 'net/http'
require 'json'
require 'uri'
require 'time'
require 'fileutils'
require 'digest'
require 'csv'

# ═══════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════
API_KEY   = ENV['ANTHROPIC_API_KEY'] || 'sk-ant-VOTRE_CLE_ICI'
API_URL   = 'https://api.anthropic.com/v1/messages'
MODEL     = 'claude-opus-4-6'
PORT      = 8080
DATA_DIR  = 'chatbot_data'

# ═══════════════════════════════════════════════════
#  STOCKAGE
# ═══════════════════════════════════════════════════
FileUtils.mkdir_p(DATA_DIR)
FileUtils.mkdir_p("#{DATA_DIR}/exports")
FileUtils.mkdir_p("#{DATA_DIR}/backups")

def load_json(path, default)
  return default unless File.exist?(path)
  JSON.parse(File.read(path, encoding: 'utf-8'))
rescue
  default
end

$messages  = load_json("#{DATA_DIR}/messages.json",  [])
$tags      = load_json("#{DATA_DIR}/tags.json",       {})
$favorites = load_json("#{DATA_DIR}/favorites.json",  [])
$reminders = load_json("#{DATA_DIR}/reminders.json",  [])
$next_id   = $messages.any? ? $messages.map{|m| m['id']}.max + 1 : 1
$claude_history = []

def save_data
  File.write("#{DATA_DIR}/messages.json",  JSON.pretty_generate($messages),  encoding: 'utf-8')
  File.write("#{DATA_DIR}/tags.json",      JSON.pretty_generate($tags),      encoding: 'utf-8')
  File.write("#{DATA_DIR}/favorites.json", JSON.pretty_generate($favorites), encoding: 'utf-8')
  File.write("#{DATA_DIR}/reminders.json", JSON.pretty_generate($reminders), encoding: 'utf-8')
  # backup auto toutes les 20 msgs utilisateur
  u = $messages.select{|m| m['role']=='user'}
  if u.size > 0 && u.size % 20 == 0
    File.write("#{DATA_DIR}/backups/backup_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json",
               JSON.pretty_generate($messages), encoding: 'utf-8')
  end
end

AUTO_CATS = {
  'travail'   => %w[travail bureau réunion projet client boss collègue],
  'personnel' => %w[famille ami maison perso moi],
  'idees'     => %w[idée penser créer inventer concept],
  'taches'    => %w[faire acheter tâche devoir obligation],
  'important' => %w[important urgent critique vital nécessaire],
  'souvenirs' => %w[souvenir rappeler mémoire vieux avant]
}

def auto_cat(text)
  t = text.downcase
  AUTO_CATS.each{|cat, kws| return cat if kws.any?{|k| t.include?(k)}}
  'divers'
end

def add_msg(role, content, tags=[])
  now = Time.now
  m = {
    'id'       => $next_id,
    'role'     => role,
    'content'  => content,
    'category' => role == 'user' ? auto_cat(content) : 'bot',
    'tags'     => tags,
    'date'     => now.strftime('%d/%m/%Y'),
    'heure'    => now.strftime('%H:%M:%S'),
    'date_complete' => now.strftime('%d/%m/%Y à %H:%M:%S'),
    'mois'     => now.strftime('%m'),
    'mois_nom' => now.strftime('%B'),
    'annee'    => now.strftime('%Y'),
    'mots'     => content.split.size,
    'longueur' => content.length
  }
  $messages << m
  $next_id  += 1
  tags.each{|t| $tags[t] ||= []; $tags[t] << m['id']}
  save_data
  m
end

def user_msgs
  $messages.select{|m| m['role']=='user'}
end

# ═══════════════════════════════════════════════════
#  API CLAUDE
# ═══════════════════════════════════════════════════
def call_claude(text)
  $claude_history << {role: 'user', content: text}
  uri  = URI(API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30
  req = Net::HTTP::Post.new(uri)
  req['Content-Type']      = 'application/json'
  req['x-api-key']         = API_KEY
  req['anthropic-version'] = '2023-06-01'
  req.body = {
    model:      MODEL,
    max_tokens: 1024,
    system:     "Tu es un assistant IA utile et bienveillant. Réponds toujours en français. L'utilisateur a #{user_msgs.size} messages stockés.",
    messages:   $claude_history
  }.to_json
  res    = http.request(req)
  parsed = JSON.parse(res.body)
  if parsed['error']
    $claude_history.pop
    return "Erreur API: #{parsed['error']['message']}"
  end
  reply = parsed.dig('content', 0, 'text') || 'Pas de réponse.'
  $claude_history << {role: 'assistant', content: reply}
  reply
rescue => e
  $claude_history.pop
  "Erreur: #{e.message}"
end

# ═══════════════════════════════════════════════════
#  COMMANDES LOCALES
# ═══════════════════════════════════════════════════
def handle_command(raw)
  m = raw.downcase.strip

  # Voir messages
  if m == 'tous mes messages' || m == 'mon historique'
    u = user_msgs
    return "Aucun message stocké." if u.empty?
    r = "=== #{u.size} MESSAGES STOCKES ===\n\n"
    u.each_with_index do |msg, i|
      fav = $favorites.include?(msg['id']) ? '[FAV] ' : ''
      r += "#{i+1}. #{fav}[ID:#{msg['id']}] #{msg['date_complete']}\n"
      r += "   #{msg['content']}\n"
      r += "   Categorie: #{msg['category']} | #{msg['mots']} mots\n\n"
    end
    return r
  end

  if m =~ /^(\d+) derniers? messages?$/ || m == 'dernier message'
    n = m == 'dernier message' ? 1 : $1.to_i
    u = user_msgs.last(n).reverse
    return "Aucun message." if u.empty?
    r = "=== #{u.size} DERNIER(S) MESSAGE(S) ===\n\n"
    u.each_with_index{|msg,i| r += "#{i+1}. [#{msg['heure']}] #{msg['content']}\n   ID:#{msg['id']} | #{msg['category']}\n\n"}
    return r
  end

  if m =~ /^(\d+) premiers? messages?$/ || m == 'premier message'
    n = m == 'premier message' ? 1 : $1.to_i
    u = user_msgs.first(n)
    return "Aucun message." if u.empty?
    r = "=== #{u.size} PREMIER(S) MESSAGE(S) ===\n\n"
    u.each_with_index{|msg,i| r += "#{i+1}. [#{msg['date']}] #{msg['content']}\n\n"}
    return r
  end

  if m =~ /^message id (\d+)$/
    msg = $messages.find{|x| x['id']==$1.to_i && x['role']=='user'}
    return "Message ID #{$1} introuvable." unless msg
    return "=== MESSAGE ID #{$1} ===\n" \
           "Date    : #{msg['date_complete']}\n" \
           "Contenu : #{msg['content']}\n" \
           "Cat.    : #{msg['category']}\n" \
           "Tags    : #{msg['tags'].any? ? msg['tags'].join(', ') : 'aucun'}\n" \
           "Favori  : #{$favorites.include?(msg['id']) ? 'Oui' : 'Non'}\n" \
           "Mots    : #{msg['mots']}"
  end

  # Recherche
  if m =~ /^recherche (.+)$/
    kw = $1.strip
    res = user_msgs.select{|x| x['content'].downcase.include?(kw.downcase)}
    return "Aucun resultat pour '#{kw}'." if res.empty?
    r = "=== RECHERCHE '#{kw}' : #{res.size} resultat(s) ===\n\n"
    res.each{|msg| r += "[ID:#{msg['id']}] #{msg['date']} - #{msg['content']}\n\n"}
    return r
  end

  # Categories
  if m == 'categories' || m == 'toutes categories'
    u = user_msgs
    return "Aucun message." if u.empty?
    cats = u.group_by{|x| x['category']}
    r = "=== CATEGORIES ===\n\n"
    cats.sort_by{|_,v| -v.size}.each do |cat, list|
      r += "#{cat.upcase}: #{list.size} message(s)\n"
    end
    return r
  end

  if m =~ /^categorie (.+)$/
    cat = $1.strip
    res = user_msgs.select{|x| x['category'].downcase.include?(cat.downcase)}
    return "Aucun message dans '#{cat}'." if res.empty?
    r = "=== CATEGORIE: #{cat.upcase} (#{res.size} msgs) ===\n\n"
    res.each{|msg| r += "[#{msg['date']}] #{msg['content']}\n\n"}
    return r
  end

  # Tags
  if m == 'tous les tags' || m == 'tags'
    return "Aucun tag utilise." if $tags.empty?
    r = "=== TAGS ===\n\n"
    $tags.sort_by{|_,v| -v.size}.each{|t,ids| r += "#{t}: #{ids.size} message(s)\n"}
    return r
  end

  if m =~ /^tag (.+)$/
    tag = $1.strip
    ids = $tags[tag] || []
    msgs = $messages.select{|x| ids.include?(x['id']) && x['role']=='user'}
    return "Aucun message avec le tag '#{tag}'." if msgs.empty?
    r = "=== TAG: #{tag} (#{msgs.size} msgs) ===\n\n"
    msgs.each{|msg| r += "[#{msg['date']}] #{msg['content']}\n\n"}
    return r
  end

  if m =~ /^ajoute tag (\S+) au message (\d+)$/
    tag, id = $1, $2.to_i
    msg = $messages.find{|x| x['id']==id && x['role']=='user'}
    return "Message ID #{id} introuvable." unless msg
    msg['tags'] ||= []
    msg['tags'] << tag unless msg['tags'].include?(tag)
    $tags[tag] ||= []
    $tags[tag] << id unless $tags[tag].include?(id)
    save_data
    return "Tag '#{tag}' ajoute au message ID #{id}."
  end

  # Favoris
  if m == 'mes favoris' || m == 'favoris'
    favs = $messages.select{|x| $favorites.include?(x['id']) && x['role']=='user'}
    return "Aucun favori." if favs.empty?
    r = "=== VOS #{favs.size} FAVORIS ===\n\n"
    favs.each_with_index{|msg,i| r += "#{i+1}. ID #{msg['id']} - #{msg['date']}\n   #{msg['content']}\n\n"}
    return r
  end

  if m =~ /^favori id (\d+)$/
    id = $1.to_i
    msg = $messages.find{|x| x['id']==id && x['role']=='user'}
    return "Message ID #{id} introuvable." unless msg
    return "Deja en favori." if $favorites.include?(id)
    $favorites << id
    save_data
    return "Message ID #{id} ajoute aux favoris !"
  end

  if m =~ /^unfavori id (\d+)$/
    id = $1.to_i
    return "Pas dans les favoris." unless $favorites.delete(id)
    save_data
    return "Message ID #{id} retire des favoris."
  end

  # Stats
  if m == 'statistiques' || m == 'stats'
    u = user_msgs
    return "Aucune donnee." if u.empty?
    words = u.map{|x| x['mots']}
    r  = "=== STATISTIQUES ===\n\n"
    r += "Messages envoyes : #{u.size}\n"
    r += "Reponses recues  : #{$messages.select{|x| x['role']=='bot'}.size}\n"
    r += "Mots (moyenne)   : #{(words.sum.to_f/u.size).round(1)}\n"
    r += "Message + long   : #{words.max} mots\n"
    r += "Message + court  : #{words.min} mots\n"
    r += "Total mots       : #{words.sum}\n"
    r += "Favoris          : #{$favorites.size}\n"
    r += "Tags             : #{$tags.size}\n"
    r += "Backups          : #{Dir.glob("#{DATA_DIR}/backups/*.json").size}\n\n"
    cats = u.group_by{|x| x['category']}
    r += "CATEGORIES:\n"
    cats.sort_by{|_,v| -v.size}.each do |cat, list|
      pct = (list.size.to_f/u.size*100).round(1)
      r += "  #{cat}: #{list.size} msgs (#{pct}%)\n"
    end
    return r
  end

  # Nuage de mots
  if m == 'nuage de mots' || m == 'wordcloud'
    u = user_msgs
    return "Aucun message." if u.empty?
    stops = %w[le la les un une des de du et est ce qui que en je tu il elle nous vous ils elles mon ma mes ton ta ses son]
    freq  = u.flat_map{|x| x['content'].downcase.split(/\W+/)}
              .reject{|w| w.length < 3 || stops.include?(w)}
              .tally.sort_by{|_,c| -c}.first(20)
    r = "=== NUAGE DE MOTS (Top 20) ===\n\n"
    freq.each{|word, count| r += "  #{word.ljust(18)} #{count}x\n"}
    return r
  end

  # Timeline
  if m == 'timeline'
    u = user_msgs
    return "Aucun message." if u.empty?
    r = "=== TIMELINE ===\n\n"
    u.group_by{|x| x['date']}.each do |date, msgs|
      r += "#{date} - #{msgs.size} message(s)\n"
      r += "  " + ("o" * [msgs.size, 30].min) + "\n\n"
    end
    return r
  end

  # Export
  if m == 'export json'
    u = user_msgs
    path = "#{DATA_DIR}/exports/export_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    File.write(path, JSON.pretty_generate({date: Time.now.to_s, total: u.size, messages: u}), encoding: 'utf-8')
    return "Export JSON cree: #{path}\n#{u.size} messages exportes."
  end

  if m == 'export csv'
    path = "#{DATA_DIR}/exports/export_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv"
    CSV.open(path, 'w') do |csv|
      csv << %w[ID Date Heure Message Categorie Mots Tags Favori]
      user_msgs.each{|msg| csv << [msg['id'],msg['date'],msg['heure'],msg['content'],msg['category'],msg['mots'],msg['tags'].join(';'),$favorites.include?(msg['id']) ? 'Oui' : 'Non']}
    end
    return "Export CSV cree: #{path}"
  end

  if m == 'export html'
    rows = user_msgs.map{|msg| "<tr><td>#{msg['id']}</td><td>#{msg['date']}</td><td>#{msg['heure']}</td><td>#{msg['content']}</td><td>#{msg['category']}</td></tr>"}.join
    path = "#{DATA_DIR}/exports/export_#{Time.now.strftime('%Y%m%d_%H%M%S')}.html"
    File.write(path, "<html><head><meta charset='UTF-8'><style>body{font-family:sans-serif;padding:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:8px}th{background:#333;color:#fff}</style></head><body><h1>Export - #{user_msgs.size} messages</h1><table><tr><th>ID</th><th>Date</th><th>Heure</th><th>Message</th><th>Categorie</th></tr>#{rows}</table></body></html>", encoding: 'utf-8')
    return "Export HTML cree: #{path}"
  end

  # Backups
  if m == 'backups' || m == 'liste backups'
    files = Dir.glob("#{DATA_DIR}/backups/*.json")
    return "Aucun backup." if files.empty?
    r = "=== BACKUPS (#{files.size}) ===\n\n"
    files.each_with_index{|f,i| r += "#{i+1}. #{File.basename(f)} - #{(File.size(f)/1024.0).round(1)}KB\n"}
    return r
  end

  # Mois / Annee
  if m =~ /^messages mois (\d+)(?: (\d{4}))?$/
    mois = $1.rjust(2,'0')
    annee = ($2 || Time.now.year).to_s
    res = user_msgs.select{|x| x['mois']==mois && x['annee']==annee}
    return "Aucun message pour #{mois}/#{annee}." if res.empty?
    r = "=== MESSAGES #{mois}/#{annee} (#{res.size}) ===\n\n"
    res.each{|msg| r += "[#{msg['heure']}] #{msg['content']}\n\n"}
    return r
  end

  if m =~ /^messages annee (\d{4})$/
    res = user_msgs.select{|x| x['annee']==$1}
    return "Aucun message en #{$1}." if res.empty?
    r = "=== MESSAGES #{$1} (#{res.size}) ===\n\n"
    res.group_by{|x| x['mois_nom']}.each{|mn,list| r += "#{mn}: #{list.size} message(s)\n"}
    return r
  end

  # Rappels
  if m =~ /^rappelle moi (.+) dans (\d+) jours?$/
    date = (Time.now + $2.to_i * 86400).strftime('%d/%m/%Y')
    $reminders << {'text' => $1, 'date' => date}
    save_data
    return "Rappel cree pour le #{date}: #{$1}"
  end

  if m == 'mes rappels' || m == 'rappels'
    return "Aucun rappel." if $reminders.empty?
    r = "=== RAPPELS ===\n\n"
    $reminders.each_with_index{|n,i| r += "#{i+1}. #{n['date']} - #{n['text']}\n"}
    return r
  end

  # Suppression
  if m =~ /^supprimer id (\d+)$/
    return "Pour confirmer, tapez: confirme supprimer #{$1}"
  end

  if m =~ /^confirme supprimer (\d+)$/
    id = $1.to_i
    msg = $messages.find{|x| x['id']==id && x['role']=='user'}
    return "Message ID #{id} introuvable." unless msg
    $messages.delete(msg)
    $favorites.delete(id)
    save_data
    return "Message ID #{id} supprime."
  end

  # Aide
  if m == 'aide' || m == 'help'
    return <<~AIDE
      === COMMANDES DISPONIBLES ===

      VOIR MESSAGES:
        tous mes messages
        dernier message | 5 derniers messages
        premier message | 5 premiers messages
        message id [N]
        messages mois 01 2025
        messages annee 2025

      RECHERCHE:
        recherche [mot]
        categorie [nom]
        tag [nom]

      CATEGORIES & TAGS:
        categories
        ajoute tag [nom] au message [ID]
        tous les tags

      FAVORIS:
        favori id [N]
        unfavori id [N]
        mes favoris

      STATISTIQUES:
        statistiques
        nuage de mots
        timeline

      EXPORT:
        export json | export csv | export html
        backups

      RAPPELS:
        rappelle moi [texte] dans 2 jours
        mes rappels

      SUPPRESSION:
        supprimer id [N]
        confirme supprimer [N]

      Tout autre message est envoye a Claude IA !
    AIDE
  end

  nil # pas une commande locale
end

# ═══════════════════════════════════════════════════
#  TRAITEMENT MESSAGE
# ═══════════════════════════════════════════════════
def process(text)
  local = handle_command(text)
  if local
    add_msg('user', text)
    add_msg('bot', local)
    return local
  end
  add_msg('user', text)
  reply = call_claude(text)
  add_msg('bot', reply)
  reply
end

# ═══════════════════════════════════════════════════
#  HTML - INTERFACE
# ═══════════════════════════════════════════════════
HTML_PAGE = <<~'HTML'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Chatbot Ultra</title>
<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#07080d;--sur:#0f1117;--sur2:#161820;--brd:#1f2133;--brd2:#2a2d45;
  --acc:#5b63f5;--acc2:#f55b8c;--acc3:#5bf5c8;
  --txt:#e2e4f0;--mut:#4a4d6a;--mut2:#6b6e8a;--r:14px
}
html,body{height:100%;overflow:hidden;background:var(--bg);color:var(--txt);font-family:'Outfit',sans-serif}
body::before{content:'';position:fixed;inset:0;background:radial-gradient(ellipse 60% 40% at 20% 10%,rgba(91,99,245,.08),transparent 60%),radial-gradient(ellipse 50% 30% at 80% 90%,rgba(245,91,140,.06),transparent 60%);pointer-events:none;z-index:0}

.layout{display:flex;height:100vh;position:relative;z-index:1}

/* SIDEBAR */
.sb{width:240px;flex-shrink:0;background:var(--sur);border-right:1px solid var(--brd);display:flex;flex-direction:column;overflow-y:auto;overflow-x:hidden}
.sb-head{padding:20px 16px 14px;border-bottom:1px solid var(--brd)}
.logo{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.logo-ico{width:36px;height:36px;background:linear-gradient(135deg,var(--acc),var(--acc2));border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:17px;flex-shrink:0;box-shadow:0 4px 14px rgba(91,99,245,.3)}
.logo-txt h1{font-size:.95rem;font-weight:700}
.logo-txt p{font-size:.6rem;color:var(--mut2);margin-top:1px}
.sgrid{display:grid;grid-template-columns:1fr 1fr;gap:5px}
.sc{background:var(--sur2);border:1px solid var(--brd);border-radius:8px;padding:7px 9px;text-align:center}
.sc .v{font-family:'JetBrains Mono',monospace;font-size:1rem;font-weight:600;color:var(--acc3)}
.sc .l{font-size:.55rem;color:var(--mut2);text-transform:uppercase;letter-spacing:.06em;margin-top:1px}
.sb-sec{padding:12px 14px 6px;font-size:.58rem;text-transform:uppercase;letter-spacing:.1em;color:var(--mut);font-weight:600}
.sb-btn{display:flex;align-items:center;gap:9px;margin:1px 8px;padding:8px 11px;border-radius:8px;border:none;background:transparent;color:var(--mut2);font-family:'Outfit',sans-serif;font-size:.78rem;cursor:pointer;text-align:left;transition:all .15s;width:calc(100% - 16px)}
.sb-btn:hover{background:var(--sur2);color:var(--txt)}
.sb-btn .ic{font-size:13px;width:17px;text-align:center}
.sb-foot{margin-top:auto;padding:10px 14px;border-top:1px solid var(--brd);font-size:.6rem;color:var(--mut);text-align:center}

/* MAIN */
.main{flex:1;display:flex;flex-direction:column;min-width:0}
.topbar{display:flex;align-items:center;gap:10px;padding:14px 20px;border-bottom:1px solid var(--brd);background:var(--sur);flex-shrink:0}
.dot{width:8px;height:8px;border-radius:50%;background:var(--acc3);box-shadow:0 0 6px var(--acc3);animation:blink 2s infinite;flex-shrink:0}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.4}}
.tb-title{font-size:.9rem;font-weight:600}
.tb-sub{font-size:.65rem;color:var(--mut2);margin-top:1px}
.tb-acts{margin-left:auto;display:flex;gap:7px}
.ico-btn{width:32px;height:32px;background:var(--sur2);border:1px solid var(--brd);border-radius:7px;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:14px;transition:all .15s;color:var(--mut2)}
.ico-btn:hover{border-color:var(--acc);color:var(--txt)}

#messages{flex:1;overflow-y:auto;padding:18px 20px;display:flex;flex-direction:column;gap:4px;scrollbar-width:thin;scrollbar-color:var(--brd) transparent}
#messages::-webkit-scrollbar{width:4px}
#messages::-webkit-scrollbar-thumb{background:var(--brd2);border-radius:4px}

.mw{display:flex;flex-direction:column;max-width:74%;animation:mIn .25s ease forwards;opacity:0}
@keyframes mIn{from{opacity:0;transform:translateY(7px)}to{opacity:1;transform:translateY(0)}}
.mw.user{align-self:flex-end;align-items:flex-end}
.mw.bot{align-self:flex-start;align-items:flex-start}
.mm{font-size:.58rem;letter-spacing:.06em;text-transform:uppercase;color:var(--mut);margin-bottom:4px;padding:0 3px}
.mw.user .mm{color:var(--acc)}
.mw.bot .mm{color:var(--acc2)}
.mb{padding:10px 14px;border-radius:var(--r);font-size:.87rem;line-height:1.65;white-space:pre-wrap;word-break:break-word}
.mw.user .mb{background:linear-gradient(135deg,#1a1d40,#1e2048);border:1px solid rgba(91,99,245,.3);border-bottom-right-radius:4px}
.mw.bot .mb{background:var(--sur2);border:1px solid var(--brd);border-bottom-left-radius:4px;font-family:'JetBrains Mono',monospace;font-size:.78rem}

.dots{display:flex;gap:4px;align-items:center;padding:2px 0}
.dots span{width:5px;height:5px;background:var(--mut2);border-radius:50%;animation:db 1.2s infinite}
.dots span:nth-child(2){animation-delay:.2s}
.dots span:nth-child(3){animation-delay:.4s}
@keyframes db{0%,60%,100%{transform:translateY(0);opacity:.4}30%{transform:translateY(-4px);opacity:1}}

.ia{flex-shrink:0;padding:12px 20px 16px;border-top:1px solid var(--brd);background:var(--sur)}
.ir{display:flex;gap:9px;align-items:flex-end;background:var(--sur2);border:1px solid var(--brd);border-radius:18px;padding:9px 9px 9px 16px;transition:border-color .2s,box-shadow .2s}
.ir:focus-within{border-color:rgba(91,99,245,.5);box-shadow:0 0 0 3px rgba(91,99,245,.08)}
#inp{flex:1;background:transparent;border:none;outline:none;color:var(--txt);font-family:'Outfit',sans-serif;font-size:.88rem;resize:none;min-height:22px;max-height:100px;line-height:1.55}
#inp::placeholder{color:var(--mut)}
#sbtn{width:36px;height:36px;flex-shrink:0;background:linear-gradient(135deg,var(--acc),var(--acc2));border:none;border-radius:10px;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:opacity .2s,transform .15s;box-shadow:0 3px 12px rgba(91,99,245,.3)}
#sbtn:hover{opacity:.85;transform:scale(1.05)}
#sbtn:disabled{opacity:.3;cursor:not-allowed}
#sbtn svg{width:15px;height:15px;fill:white}
.hint{font-size:.6rem;color:var(--mut);text-align:center;margin-top:7px}

#toast{position:fixed;bottom:80px;left:50%;transform:translateX(-50%);background:var(--sur2);border:1px solid var(--brd2);color:var(--txt);padding:7px 16px;border-radius:18px;font-size:.78rem;opacity:0;transition:opacity .3s;pointer-events:none;z-index:100}
</style>
</head>
<body>
<div class="layout">

<aside class="sb">
  <div class="sb-head">
    <div class="logo">
      <div class="logo-ico">✦</div>
      <div class="logo-txt"><h1>Chatbot Ultra</h1><p>Claude IA + Stockage</p></div>
    </div>
    <div class="sgrid">
      <div class="sc"><div class="v" id="sm">0</div><div class="l">Messages</div></div>
      <div class="sc"><div class="v" id="sf">0</div><div class="l">Favoris</div></div>
      <div class="sc"><div class="v" id="st">0</div><div class="l">Tags</div></div>
      <div class="sc"><div class="v" id="si">1</div><div class="l">Prochain ID</div></div>
    </div>
  </div>

  <div class="sb-sec">Consultation</div>
  <button class="sb-btn" id="b1"><span class="ic">📜</span>Tous mes messages</button>
  <button class="sb-btn" id="b2"><span class="ic">📌</span>5 derniers messages</button>
  <button class="sb-btn" id="b3"><span class="ic">⭐</span>Mes favoris</button>
  <button class="sb-btn" id="b4"><span class="ic">🏷️</span>Catégories</button>

  <div class="sb-sec">Analyse</div>
  <button class="sb-btn" id="b5"><span class="ic">📊</span>Statistiques</button>
  <button class="sb-btn" id="b6"><span class="ic">☁️</span>Nuage de mots</button>
  <button class="sb-btn" id="b7"><span class="ic">⏱️</span>Timeline</button>

  <div class="sb-sec">Export</div>
  <button class="sb-btn" id="b8"><span class="ic">💾</span>Export JSON</button>
  <button class="sb-btn" id="b9"><span class="ic">📊</span>Export CSV</button>
  <button class="sb-btn" id="b10"><span class="ic">🌐</span>Export HTML</button>

  <div class="sb-sec">Outils</div>
  <button class="sb-btn" id="b11"><span class="ic">📦</span>Backups</button>
  <button class="sb-btn" id="b12"><span class="ic">🔔</span>Rappels</button>
  <button class="sb-btn" id="b13"><span class="ic">❓</span>Aide</button>

  <div class="sb-foot">Données: chatbot_data/<br>Backup auto / 20 msgs</div>
</aside>

<main class="main">
  <div class="topbar">
    <div class="dot"></div>
    <div><div class="tb-title">Assistant Claude</div><div class="tb-sub">IA + commandes locales</div></div>
    <div class="tb-acts">
      <button class="ico-btn" id="bsearch" title="Recherche">🔍</button>
      <button class="ico-btn" id="bclear"  title="Effacer vue">🗑️</button>
    </div>
  </div>

  <div id="messages"></div>

  <div class="ia">
    <div class="ir">
      <textarea id="inp" placeholder="Écris un message ou une commande…" rows="1"></textarea>
      <button id="sbtn" type="button">
        <svg viewBox="0 0 24 24"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
      </button>
    </div>
    <p class="hint">Entrée pour envoyer · Shift+Entrée pour saut de ligne · tape <strong>aide</strong> pour les commandes</p>
  </div>
</main>
</div>
<div id="toast"></div>

<script>
(function() {
  var msgs  = document.getElementById('messages');
  var inp   = document.getElementById('inp');
  var sbtn  = document.getElementById('sbtn');
  var busy  = false;

  // ── Helpers ────────────────────────────────────────
  function escHtml(s) {
    return String(s)
      .replace(/&/g,'&amp;')
      .replace(/</g,'&lt;')
      .replace(/>/g,'&gt;');
  }

  function addMsg(role, text) {
    var w  = document.createElement('div');
    w.className = 'mw ' + role;
    var ts = new Date().toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'});
    var lbl = role === 'user' ? '▸ Vous' : '✦ Claude';
    w.innerHTML =
      '<div class="mm">' + lbl + ' · ' + ts + '</div>' +
      '<div class="mb">' + escHtml(text) + '</div>';
    msgs.appendChild(w);
    msgs.scrollTop = msgs.scrollHeight;
  }

  function addTyping() {
    var w = document.createElement('div');
    w.className = 'mw bot'; w.id = 'typing';
    w.innerHTML =
      '<div class="mm">✦ Claude · …</div>' +
      '<div class="mb"><div class="dots"><span></span><span></span><span></span></div></div>';
    msgs.appendChild(w);
    msgs.scrollTop = msgs.scrollHeight;
  }

  function removeTyping() {
    var t = document.getElementById('typing');
    if (t) t.parentNode.removeChild(t);
  }

  function toast(msg) {
    var t = document.getElementById('toast');
    t.textContent = msg; t.style.opacity = '1';
    setTimeout(function(){ t.style.opacity = '0'; }, 2500);
  }

  function updateStats() {
    fetch('/stats')
      .then(function(r){ return r.json(); })
      .then(function(d){
        document.getElementById('sm').textContent = d.messages;
        document.getElementById('sf').textContent = d.favorites;
        document.getElementById('st').textContent = d.tags;
        document.getElementById('si').textContent = d.next_id;
      })
      .catch(function(){});
  }

  // ── Envoi ──────────────────────────────────────────
  function doSend() {
    var text = inp.value.trim();
    if (!text || busy) return;
    busy = true;
    sbtn.disabled = true;
    inp.value = '';
    inp.style.height = 'auto';
    addMsg('user', text);
    addTyping();
    fetch('/chat', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({message: text})
    })
    .then(function(r){ return r.json(); })
    .then(function(d){
      removeTyping();
      addMsg('bot', d.reply || 'Pas de reponse.');
      updateStats();
    })
    .catch(function(){
      removeTyping();
      addMsg('bot', 'Erreur de connexion au serveur.');
    })
    .then(function(){
      busy = false;
      sbtn.disabled = false;
      inp.focus();
    });
  }

  function sendCmd(cmd) {
    inp.value = cmd;
    doSend();
  }

  // ── Événements bouton + Entrée ─────────────────────
  sbtn.addEventListener('click', function(){ doSend(); });

  inp.addEventListener('keydown', function(e){
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      doSend();
    }
  });

  inp.addEventListener('input', function(){
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 100) + 'px';
  });

  // ── Boutons sidebar ────────────────────────────────
  var cmds = {
    'b1':  'tous mes messages',
    'b2':  '5 derniers messages',
    'b3':  'mes favoris',
    'b4':  'categories',
    'b5':  'statistiques',
    'b6':  'nuage de mots',
    'b7':  'timeline',
    'b8':  'export json',
    'b9':  'export csv',
    'b10': 'export html',
    'b11': 'backups',
    'b12': 'mes rappels',
    'b13': 'aide'
  };

  Object.keys(cmds).forEach(function(id) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener('click', function(){ sendCmd(cmds[id]); });
    }
  });

  // ── Boutons topbar ─────────────────────────────────
  document.getElementById('bsearch').addEventListener('click', function(){
    inp.value = 'recherche ';
    inp.focus();
  });

  document.getElementById('bclear').addEventListener('click', function(){
    msgs.innerHTML = '';
    toast('Vue effacée — messages conservés en base');
  });

  // ── Init ───────────────────────────────────────────
  addMsg('bot',
    "Chatbot Ultra demarre !\n\n" +
    "Je suis connecte a Claude IA pour repondre a vos questions.\n" +
    "Tous vos messages sont stockes automatiquement.\n\n" +
    "Tapez aide pour voir toutes les commandes.\n" +
    "Utilisez la barre de gauche pour acces rapide."
  );
  updateStats();
  setInterval(updateStats, 5000);
  inp.focus();
})();
</script>
</body>
</html>
HTML

# ═══════════════════════════════════════════════════
#  SERVEUR
# ═══════════════════════════════════════════════════
server = WEBrick::HTTPServer.new(
  Port:        PORT,
  BindAddress: 'localhost',
  Logger:      WEBrick::Log.new(File::NULL),
  AccessLog:   []
)

server.mount_proc('/') do |_req, res|
  res['Content-Type'] = 'text/html; charset=UTF-8'
  res.body = HTML_PAGE
end

server.mount_proc('/chat') do |req, res|
  body    = JSON.parse(req.body) rescue {}
  message = (body['message'] || '').to_s.strip
  reply   = message.empty? ? 'Message vide.' : process(message)
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate({reply: reply})
end

server.mount_proc('/stats') do |_req, res|
  u = user_msgs
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate({
    messages:  u.size,
    favorites: $favorites.size,
    tags:      $tags.size,
    next_id:   $next_id
  })
end

puts ""
puts "  #{"═"*50}"
puts "    Chatbot Ultra - Serveur demarre !"
puts "  #{"═"*50}"
puts "  URL     : http://localhost:#{PORT}"
puts "  Donnees : #{DATA_DIR}/"
puts "  Ctrl+C  : arreter"
puts "  #{"═"*50}"
puts ""

Thread.new { sleep 1; system("start http://localhost:#{PORT}") }

trap('INT') do
  puts "\nSauvegarde..."
  save_data
  puts "#{user_msgs.size} messages sauvegardes. Au revoir !"
  server.shutdown
end

server.start
