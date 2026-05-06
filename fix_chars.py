import re

with open('app.html', 'rb') as f:
    content = f.read()

# Decode trying different encodings
try:
    text = content.decode('cp1252')
except:
    text = content.decode('utf-8', errors='replace')

# Replace double ?? with chart emoji  
text = text.replace('??', '📊')

# Replace single ? followed by space
patterns = [
    ('? Retour', '← Retour'),
    ('? Accueil', '🏠 Accueil'),
    ('? Calculer', '📊 Calculer'),
    ('? Apports', '📈 Apports'),
    ('? Besoins', '📊 Besoins'),
    ('? Bilan', '📊 Bilan'),
    ('? Ma ration', '📊 Ma ration'),
    ('? Profils', '📊 Profils'),
    ('? Gestion', '🔧 Gestion'),
    ('? Calculateur', '📏 Calculateur'),
    ('? Analyse IA', '🤖 Analyse IA'),
    ('? PDF', '📄 PDF'),
    ('? Coûts', '💰 Coûts'),
]

for old, new in patterns:
    text = text.replace(old, new)

with open('app.html', 'w', encoding='utf-8') as f:
    f.write(text)
print('Done')