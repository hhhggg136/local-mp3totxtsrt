"""Project-isolated corrections, with explicit approval before recognition hints."""
import hashlib
import sqlite3
import unicodedata
from collections import Counter
from pathlib import Path
from .core import UserError, parse_srt

class LearningStore:
    def __init__(self,path):
        Path(path).parent.mkdir(parents=True,exist_ok=True)
        self.db=sqlite3.connect(str(path),timeout=3)
        self.db.execute('PRAGMA cache_size=-1024')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY,project TEXT NOT NULL,wrong TEXT NOT NULL,right TEXT NOT NULL,count INTEGER NOT NULL DEFAULT 1,enabled INTEGER NOT NULL DEFAULT 0,UNIQUE(project,wrong,right));CREATE TABLE IF NOT EXISTS imports(fingerprint TEXT PRIMARY KEY);''')
    def close(self):self.db.close()
    @staticmethod
    def key(name):
        name=unicodedata.normalize('NFC',name.strip())
        if not 0<len(name)<=80:raise UserError('项目名称须为 1–80 个字。')
        return name
    @staticmethod
    def correction(a,b):
        p=0
        while p<min(len(a),len(b)) and a[p]==b[p]:p+=1
        s=0
        while s<min(len(a),len(b))-p and a[len(a)-1-s]==b[len(b)-1-s]:s+=1
        wrong=a[p:len(a)-s if s else len(a)];right=b[p:len(b)-s if s else len(b)]
        if not (0<len(wrong)<=8 and 0<len(right)<=8 and wrong!=right and wrong.isalnum() and right.isalnum()):return None
        left=''
        for c in reversed(a[max(0,p-2):p]):
            if not c.isalnum():break
            left=c+left
        tail=''
        for c in a[len(a)-s:len(a)-s+2] if s else '':
            if not c.isalnum():break
            tail+=c
        return left+wrong+tail,left+right+tail
    def import_pair(self,original,corrected,project):
        project=self.key(project);before=parse_srt(original);after=parse_srt(corrected)
        key=hashlib.sha256((project+':'+hashlib.sha256(original.encode()).hexdigest()+':'+hashlib.sha256(corrected.encode()).hexdigest()).encode()).hexdigest()
        if self.db.execute('SELECT 1 FROM imports WHERE fingerprint=?',(key,)).fetchone():return {'learned':0,'unmatched':0,'duplicate':True}
        a=Counter((c.span.start,c.span.end) for c in before);b=Counter((c.span.start,c.span.end) for c in after)
        lookup={(c.span.start,c.span.end):c for c in before};learned=unmatched=0
        with self.db:
            for cue in after:
                t=(cue.span.start,cue.span.end)
                if a[t]!=1 or b[t]!=1:unmatched+=1;continue
                pair=self.correction(lookup[t].text.replace('\n',' '),cue.text.replace('\n',' '))
                if not pair:continue
                changed=self.db.execute('''INSERT INTO rules(project,wrong,right) SELECT ?,?,? WHERE (SELECT COUNT(*) FROM rules WHERE project=?)<5000 OR EXISTS(SELECT 1 FROM rules WHERE project=? AND wrong=? AND right=?) ON CONFLICT(project,wrong,right) DO UPDATE SET count=count+1''',(project,*pair,project,project,*pair)).rowcount
                if changed:learned+=1
            self.db.execute('INSERT INTO imports VALUES(?)',(key,))
        return {'learned':learned,'unmatched':unmatched,'duplicate':False}
    def entries(self,project,limit=200):
        return self.db.execute('SELECT id,wrong,right,count,enabled FROM rules WHERE project=? ORDER BY count DESC,id DESC LIMIT ?',(self.key(project),max(1,min(limit,5000)))).fetchall()
    def prompt(self,project):
        words=[]
        for (word,) in self.db.execute('SELECT DISTINCT right FROM rules WHERE project=? AND enabled=1 ORDER BY count DESC LIMIT 32',(self.key(project),)):
            if len('、'.join(words)+'、'+word)<=400:words.append(word)
        return '相关词语：'+'、'.join(words)+'。' if words else ''
    def approve(self,id,enabled):
        with self.db:self.db.execute('UPDATE rules SET enabled=? WHERE id=?',(int(enabled),id))
    def edit(self,id,value):
        value=value.strip()
        if not value or len(value)>32 or '\n' in value or '\ufffd' in value:raise UserError('正确词语须为 1–32 个字，不能有换行或乱码。')
        with self.db:self.db.execute('UPDATE rules SET right=?,enabled=0 WHERE id=?',(value,id))
    def delete(self,id):
        with self.db:self.db.execute('DELETE FROM rules WHERE id=?',(id,))
