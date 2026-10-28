"""Native Windows workspace; inference and disk processing run outside Tk's thread."""
from __future__ import annotations
import copy
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import ttk, filedialog as files, messagebox as boxes, simpledialog as dialogs
from .core import Project, History, Span, SCALE, Cancelled, UserError, load_project, save_project, read_srt, seconds_ticks, stamp
from .media import Runtime, Media, VERSION
from .player import Player
from .learning import LearningStore
from . import speakers


class Workspace:
    def __init__(self, root):
        self.root=root;self.runtime=Runtime();self.media=Media(self.runtime);self.player=Player()
        self.project=None;self.history=None;self.path=None;self.dirty=False;self.busy=False;self.closing=False
        self.events=queue.Queue();self.worker=None;self.wave=[];self.rows={};self.buttons=[]
        self.mode=tk.StringVar(value='原始时间线');self.language=tk.StringVar(value='中文')
        self.project_name=tk.StringVar(value='默认项目');self.status=tk.StringVar(value='导入本地音视频，识别后点击对白即可定位。')
        self.info=tk.StringVar(value='未载入素材');self.clock=tk.StringVar(value='00:00:00,000')
        root.title('听听兽 · 本地字幕工具 '+VERSION);root.geometry('1120x780');root.minsize(900,620)
        icon=self.runtime.root/'assets/listening-mascot.ico'
        if icon.exists():root.iconbitmap(str(icon))
        self.build();root.protocol('WM_DELETE_WINDOW',self.close);root.after(80,self.tick)

    def button(self,parent,text,command):
        button=ttk.Button(parent,text=text,command=lambda:self.guard(command));button.pack(side='left',padx=3,pady=4)
        self.buttons.append(button);return button

    def build(self):
        first=ttk.Frame(self.root,padding=(12,8));first.pack(fill='x')
        for title,fn in [('导入音视频',self.import_media),('打开项目',self.open_project),('保存项目',self.save),('导入 SRT',self.import_srt)]:self.button(first,title,fn)
        ttk.Label(first,textvariable=self.info).pack(side='left',padx=12)
        second=ttk.Frame(self.root,padding=(12,0));second.pack(fill='x')
        ttk.Label(second,text='识别语言').pack(side='left')
        self.lang_box=ttk.Combobox(second,textvariable=self.language,values=['中文','英语','西班牙语','自动检测'],state='readonly',width=10);self.lang_box.pack(side='left',padx=5)
        ttk.Label(second,text='词库项目').pack(side='left',padx=(10,0));ttk.Entry(second,textvariable=self.project_name,width=18).pack(side='left',padx=5)
        for title,fn in [('开始识别',self.recognize),('纠错词库',self.learning),('区分说话人',self.analyze),('说话人改名',self.rename)]:self.button(second,title,fn)
        ttk.Separator(self.root).pack(fill='x',pady=8)
        bar=ttk.Frame(self.root,padding=(12,0));bar.pack(fill='x')
        self.mode_box=ttk.Combobox(bar,textvariable=self.mode,values=['原始时间线','剪辑时间线'],state='readonly',width=16);self.mode_box.pack(side='left',padx=3)
        self.mode_box.bind('<<ComboboxSelected>>',lambda e:self.change_mode())
        for title,fn in [('播放 / 停止',self.play),('试听选中句',self.audition),('撤销',self.undo),('重做',self.redo),('一键翻译',self.translate),('导出',self.export)]:self.button(bar,title,fn)
        ttk.Label(bar,textvariable=self.clock).pack(side='right',padx=8)
        self.canvas=tk.Canvas(self.root,height=92,background='#edf3f6',highlightthickness=0);self.canvas.pack(fill='x',padx=15,pady=8)
        self.canvas.bind('<Configure>',lambda e:self.draw_wave());self.canvas.bind('<Button-1>',self.seek_wave)
        ttk.Label(self.root,text='原始时间线保留素材时间；剪辑时间线按保留片段顺序播放和导出。裁剪后的文字需人工核对。',padding=(15,0)).pack(anchor='w')
        frame=ttk.Frame(self.root,padding=(15,6));frame.pack(fill='both',expand=True)
        columns=('time','speaker','text','state')
        self.tree=ttk.Treeview(frame,columns=columns,show='headings',selectmode='browse')
        for key,title,width in [('time','当前时间码',190),('speaker','说话人',90),('text','对白（双击编辑）',540),('state','状态',135)]:
            self.tree.heading(key,text=title);self.tree.column(key,width=width,minwidth=70,stretch=key=='text')
        scroll=ttk.Scrollbar(frame,orient='vertical',command=self.tree.yview);self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side='left',fill='both',expand=True);scroll.pack(side='right',fill='y')
        self.tree.bind('<<TreeviewSelect>>',self.select);self.tree.bind('<Double-1>',lambda e:self.guard(self.edit_text))
        edit=ttk.Frame(self.root,padding=(12,0));edit.pack(fill='x')
        for title,fn in [('编辑对白',self.edit_text),('单句说话人',self.assign),('片段边界',self.trim),('删除 / 恢复',self.delete),('上移',lambda:self.move(-1)),('下移',lambda:self.move(1)),('已核对裁剪文字',self.review)]:self.button(edit,title,fn)
        bottom=ttk.Frame(self.root,padding=(15,8));bottom.pack(fill='x')
        ttk.Label(bottom,textvariable=self.status,wraplength=920).pack(side='left',fill='x',expand=True)
        self.cancel_button=ttk.Button(bottom,text='取消任务',command=self.cancel,state='disabled');self.cancel_button.pack(side='right')

    def guard(self,fn):
        if self.busy:return
        try:fn()
        except Exception as exc:boxes.showerror('无法继续',str(exc),parent=self.root)

    def task(self,title,fn,done):
        if self.busy:return
        self.player.stop();self.busy=True;self.runtime.reset();self.status.set(title+'；可以取消。')
        for b in self.buttons:b.configure(state='disabled')
        self.mode_box.configure(state='disabled');self.cancel_button.configure(state='normal')
        def run():
            try:self.events.put((done,fn(),None))
            except BaseException as exc:self.events.put((done,None,exc))
        self.worker=threading.Thread(target=run,daemon=True);self.worker.start()

    def cancel(self):self.runtime.request_cancel();self.status.set('正在取消并释放本次任务资源，请稍候…')

    def tick(self):
        try:
            done,result,error=self.events.get_nowait()
            # Completion is posted immediately before thread exit; never mutate
            # project/runtime concurrently with a still-running worker.
            if self.worker:self.worker.join()
            self.busy=False
            for b in self.buttons:b.configure(state='normal')
            self.mode_box.configure(state='readonly');self.cancel_button.configure(state='disabled')
            if self.closing:self.finish_close();return
            if error:
                self.status.set(str(error))
                if not isinstance(error,Cancelled):boxes.showerror('任务未完成',str(error),parent=self.root)
            else:
                try:done(result)
                except Exception as exc:boxes.showerror('无法读取处理结果',str(exc),parent=self.root)
        except queue.Empty:pass
        if self.player.error:
            self.status.set(self.player.error);self.player.error=None
        self.clock.set(stamp(self.player.position));self.draw_cursor()
        self.root.after(80,self.tick)

    def timeline(self):return self.project.timeline('original' if self.mode.get()=='原始时间线' else 'edited')
    def require(self):
        if self.project is None:raise UserError('请先导入音视频或打开项目。')
    def editable(self):
        self.require()
        if self.mode.get()!='剪辑时间线':raise UserError('请切换到剪辑时间线后调整片段。')
    def selected(self):
        self.require();ids=self.tree.selection()
        if not ids or ids[0] not in self.rows:raise UserError('请先选择一条对白或片段。')
        return self.rows[ids[0]]
    def mark(self):self.dirty=True;self.refresh()
    def discard(self):
        if not self.dirty:return True
        answer=boxes.askyesnocancel('保存编辑','当前项目有未保存的编辑，是否先保存？',parent=self.root)
        if answer is None:return False
        if answer:return self.save()
        return True
    def install(self,project,path=None):
        self.project=project;self.history=History(project);self.path=Path(path) if path else None;self.dirty=False
        self.player.seek(0);self.mode.set('原始时间线');self.info.set(project.source.file.name);self.refresh()
    def import_media(self):
        if not self.discard():return
        path=files.askopenfilename(title='选择本地音视频',parent=self.root)
        if not path:return
        def work():
            source=self.media.inspect(path);p=Project.make(source);wave=self.media.waveform(source);return p,wave
        def done(result):self.wave=result[1];self.install(result[0]);self.status.set('素材已载入。选择语言后开始识别，或导入对应 SRT。')
        self.task('读取素材并准备磁盘试听缓存',work,done)
    def open_project(self):
        if not self.discard():return
        path=files.askopenfilename(title='打开剪辑项目',filetypes=[('听听兽项目','*.tingting')],parent=self.root)
        if not path:return
        p=load_project(path);source=p.source.file
        if not source.is_file():
            source=files.askopenfilename(title='重新定位同一份原素材（将核对 SHA-256）',parent=self.root)
            if not source:return
        def work():p.source=self.media.verify(p.source,source);return p,self.media.waveform(p.source)
        def done(result):self.wave=result[1];self.install(result[0],path);self.status.set('项目已恢复；原素材校验通过。')
        self.task('校验项目素材',work,done)
    def save(self):
        self.require();path=self.path or files.asksaveasfilename(title='保存项目',defaultextension='.tingting',filetypes=[('听听兽项目','*.tingting')],parent=self.root)
        if not path:return False
        save_project(self.project,path);self.path=Path(path);self.dirty=False;self.status.set('项目已保存；再次保存时保留上一次 .bak 备份。');return True
    def import_srt(self):
        self.require()
        if self.project.cues and not boxes.askyesno('替换对白','导入 SRT 将重建当前片段并清除当前说话人归属。请先保存需要保留的编辑。继续？',parent=self.root):return
        path=files.askopenfilename(title='导入对应原素材时间码的 SRT',filetypes=[('SRT','*.srt')],parent=self.root)
        if not path:return
        p=Project.make(self.project.source,read_srt(path));self.install(p);self.mark()
    def recognize(self):
        self.require()
        if self.project.cues and not boxes.askyesno('重新识别','重新识别会替换当前对白、片段和说话人归属。已保存的项目不受影响。继续？',parent=self.root):return
        folder=files.askdirectory(title='选择识别结果保存文件夹',parent=self.root)
        if not folder:return
        language={'中文':'zh','英语':'en','西班牙语':'es','自动检测':'auto'}[self.language.get()]
        name=LearningStore.key(self.project_name.get());store=LearningStore(self.runtime.data/'learning.sqlite3')
        try:prompt=store.prompt(name)
        finally:store.close()
        source=copy.deepcopy(self.project.source)
        def done(result):self.install(result[0]);self.mark();self.status.set('识别完成，结果保存在：'+str(result[1]))
        self.task('本地识别中',lambda:self.media.recognize(source,folder,language,name,prompt),done)
    def change_mode(self):
        if self.busy:return
        self.player.seek(0);self.refresh()
    def refresh(self):
        selected=self.tree.selection();self.tree.delete(*self.tree.get_children());self.rows={}
        if not self.project:return
        timeline=self.timeline();ci={c.id:c for c in self.project.clips};di={c.id:c for c in self.project.cues}
        entries={e.clip:e for e in timeline.entries}
        order=[c.id for c in sorted(self.project.clips,key=lambda c:c.initial.start)] if self.mode.get()=='原始时间线' else self.project.order
        projected={cue.id:(span,review) for cue,_,span,review in self.project.projected(timeline)}
        for id in order:
            clip=ci[id];entry=entries.get(id)
            for cueid in clip.cues or [None]:
                cue=di.get(cueid);rowid=cueid or id;span,review=projected.get(cueid,(None,False))
                span=span or (entry.timeline if entry else None)
                text=cue.text.replace('\n',' / ') if cue else '（无对白片段）'
                state='已删除' if not entry else ('裁剪文字待检查' if review else ('已裁剪' if clip.span!=clip.initial and self.mode.get()!='原始时间线' else ''))
                self.tree.insert('', 'end', iid=rowid,values=(f'{stamp(span.start)} → {stamp(span.end)}' if span else '—',self.project.label(cueid) if cue else '',text,state))
                self.rows[rowid]=(cue,clip,span)
        if selected and selected[0] in self.rows:self.tree.selection_set(selected[0])
        self.draw_wave()
    def select(self,event=None):
        if self.busy:return
        try:
            _,_,span=self.selected()
            if span:self.player.seek(span.start)
        except UserError:pass
    def play(self):
        self.require()
        if self.player.playing:self.player.stop();return
        if self.media.preview_hash!=self.project.source.sha256:raise UserError('试听缓存与当前素材不匹配，请重新打开当前项目。')
        timeline=self.timeline();start=self.player.position if self.player.position<timeline.duration else 0
        self.player.play(self.media.preview,timeline,start)
    def audition(self):
        _,_,span=self.selected()
        if self.media.preview_hash!=self.project.source.sha256:raise UserError('试听缓存与当前素材不匹配，请重新打开当前项目。')
        if span:self.player.play(self.media.preview,self.timeline(),span.start,span.end)
    def edit_text(self):
        cue,_,_=self.selected()
        if not cue:raise UserError('此片段没有对白。')
        value=dialogs.askstring('编辑对白','修改当前句文字（不修改原始识别文稿）：',initialvalue=cue.text,parent=self.root)
        if value is not None:self.history.text(cue.id,value);self.mark()
    def trim(self):
        self.editable();_,clip,_=self.selected()
        value=dialogs.askstring('片段边界','输入原素材起止秒数，用空格分隔：',initialvalue=f'{clip.span.start/SCALE:.3f} {clip.span.end/SCALE:.3f}',parent=self.root)
        if value is None:return
        parts=value.split()
        if len(parts)!=2:raise UserError('请输入两个秒数，例如 2.500 6.000。')
        self.player.stop();self.history.trim(clip.id,Span(*map(seconds_ticks,parts)));self.mark()
    def delete(self):
        self.editable();_,clip,_=self.selected();self.player.stop();self.history.delete(clip.id,not clip.deleted);self.mark()
    def move(self,delta):
        self.editable();_,clip,_=self.selected();self.player.stop();self.history.move(clip.id,self.project.order.index(clip.id)+delta);self.mark()
    def review(self):
        self.editable();_,clip,_=self.selected();self.history.review(clip.id);self.mark()
    def undo(self):self.require();self.player.stop();self.history.undo();self.mark()
    def redo(self):self.require();self.player.stop();self.history.redo();self.mark()
    def analyze(self):
        self.require()
        count=dialogs.askinteger('区分说话人','预计人数：0 为自动，或输入 1–8。自动分组需要试听核对，重叠对白可能无法区分。',minvalue=0,maxvalue=8,initialvalue=0,parent=self.root)
        if count is None:return
        if self.project.speakers is not None and not boxes.askyesno('重新分析','将替换当前说话人标记，并清空撤销历史。已保存的项目不受影响。继续？',parent=self.root):return
        snapshot=copy.deepcopy(self.project)
        def done(result):self.history.install_speakers(result[0]);self.mark();self.status.set('本地说话人分析完成，请试听核对；分析进程已退出。')
        self.task('本地区分说话人',lambda:speakers.analyze(snapshot,self.media,count),done)
    def rename(self):
        self.require();data=self.project.speakers
        if not data or not data['speakers']:raise UserError('请先分析说话人，或用单句说话人新增编号。')
        code=dialogs.askstring('说话人改名','输入要修改的编号：'+', '.join(s['id']+'='+s['name'] for s in data['speakers']),parent=self.root)
        if code is None:return
        code=code.strip().upper();person=next((s for s in data['speakers'] if s['id']==code),None)
        if not person:raise UserError('编号不存在。')
        name=dialogs.askstring('说话人改名','输入 '+code+' 的名字：',initialvalue=person['name'],parent=self.root)
        if name is not None:self.history.rename(code,name);self.mark()
    def assign(self):
        cue,_,_=self.selected()
        if not cue:raise UserError('请选择一条对白。')
        data=self.project.speakers;people=data['speakers'] if data else []
        value=dialogs.askstring('单句说话人','输入编号；留空设为待确认；输入 + 新增编号。\n'+', '.join(s['id']+'='+s['name'] for s in people),parent=self.root)
        if value is None:return
        value=value.strip().upper()
        if value=='+':value=self.history.add_speaker()
        self.history.assign(cue.id,value or None);self.mark()
    def export(self):
        self.require();timeline=self.timeline();rows=self.project.projected(timeline)
        if not boxes.askyesno('确认导出',f'时间线：{self.mode.get()}\n保留片段：{len(timeline.entries)}\n字幕条数：{len(rows)}\n裁剪文字待检查：{sum(r[3] for r in rows)}\n\n按此时间线导出音频和字幕？',parent=self.root):return
        format=dialogs.askstring('音频格式','输入 m4a、wav，或 srt（仅字幕）：',initialvalue='m4a',parent=self.root)
        if format is None:return
        format=format.strip().lower()
        if format not in ['m4a','wav','srt']:raise UserError('格式须为 m4a、wav 或 srt。')
        folder=files.askdirectory(title='导出到文件夹',parent=self.root)
        if not folder:return
        names=bool(self.project.speakers) and boxes.askyesno('说话人名字','字幕前是否添加当前说话人名字？',parent=self.root)
        snapshot=copy.deepcopy(self.project);mode='original' if self.mode.get()=='原始时间线' else 'edited'
        self.task('导出中',lambda:self.media.export(snapshot,folder,mode,format,names,format!='srt'),lambda result:self.status.set('导出完成：'+str(result)))
    def translate(self):
        self.require()
        from .translation import Translation, route
        value=dialogs.askstring('一键翻译','输入原文和译文语言代码，用空格分隔。\n中文 zh、英语 en、西班牙语 es；例如 zh en。\n中西互译经英语中转，译文需要人工核对。',initialvalue='zh en',parent=self.root)
        if value is None:return
        parts=value.strip().split()
        if len(parts)!=2:raise UserError('请输入原文和译文两个语言代码。')
        source,target=parts;route(source,target);translator=Translation(self.runtime)
        missing=translator.missing(source,target);imports={}
        if missing:
            summary='\n\n'.join(f'{pair}：{info["bytes"]/1048576:.1f} MiB\n来源：{info["url"]}' for pair,info in missing)
            choice=boxes.askyesnocancel('配置离线语言包',summary+'\n\n保存位置：'+str(translator.root)+'\n\n“是”下载语言包；“否”选择已有 .argosmodel；“取消”退出。下载后翻译在本地运行，字幕不上传。',parent=self.root)
            if choice is None:return
            if not choice:
                for pair,_ in missing:
                    path=files.askopenfilename(title='选择 '+pair+' 官方语言包',filetypes=[('Argos 模型','*.argosmodel')],parent=self.root)
                    if not path:return
                    imports[pair]=path
        folder=files.askdirectory(title='保存额外译文和双语字幕',parent=self.root)
        if not folder:return
        mode='original' if self.mode.get()=='原始时间线' else 'edited';snapshot=copy.deepcopy(self.project)
        if not boxes.askyesno('确认翻译',f'当前时间线：{self.mode.get()}\n对白：{len(snapshot.projected(snapshot.timeline(mode)))} 条\n\n额外生成译文 SRT、译文 TXT 和双语 SRT，原文保留。继续？',parent=self.root):return
        def work():
            for pair,_ in missing:translator.install(pair,imports.get(pair))
            return translator.translate(snapshot,folder,source,target,mode,bool(snapshot.speakers))
        self.task('本地翻译；首次可能需要下载语言包',work,lambda result:self.status.set('译文和双语字幕已生成：'+str(result)))
    def learning(self):
        name=LearningStore.key(self.project_name.get());store=LearningStore(self.runtime.data/'learning.sqlite3')
        window=tk.Toplevel(self.root);window.title('本地纠错词库 · '+name);window.geometry('700x420')
        ttk.Label(window,text='导回修改后的字幕，生成待审核词条；启用后才作为下次识别提示，不训练或上传音频。',wraplength=660,padding=10).pack()
        tree=ttk.Treeview(window,columns=('wrong','right','count','enabled'),show='headings',selectmode='browse')
        for key,title in [('wrong','原识别'),('right','正确词语'),('count','次数'),('enabled','已启用')]:tree.heading(key,text=title);tree.column(key,width=140)
        tree.pack(fill='both',expand=True,padx=10)
        def refresh():
            tree.delete(*tree.get_children())
            for id,wrong,right,count,enabled in store.entries(name,5000):tree.insert('','end',iid=str(id),values=(wrong,right,count,'是' if enabled else '否'))
        def invoke(fn):
            try:fn();refresh()
            except Exception as exc:boxes.showerror('词库操作未完成',str(exc),parent=window)
        def selected():
            ids=tree.selection()
            if not ids:raise UserError('请先选择词条。')
            return int(ids[0])
        def import_pair():
            a=files.askopenfilename(title='选择识别时保存的学习基准.srt',filetypes=[('SRT','*.srt')],parent=window)
            if not a:return
            b=files.askopenfilename(title='选择已修改文字、保留原时间码的 SRT',filetypes=[('SRT','*.srt')],parent=window)
            if not b:return
            result=store.import_pair(read_srt(a),read_srt(b),name)
            boxes.showinfo('学习结果',f'新增或累计：{result["learned"]}\n时间码无法唯一匹配：{result["unmatched"]}\n重复导入：{result["duplicate"]}',parent=window)
        def edit():
            id=selected();value=dialogs.askstring('编辑词条','正确词语：',initialvalue=tree.item(str(id),'values')[1],parent=window)
            if value is not None:store.edit(id,value)
        bar=ttk.Frame(window);bar.pack(pady=8)
        for title,fn in [('导入纠错字幕',import_pair),('启用',lambda:store.approve(selected(),True)),('停用',lambda:store.approve(selected(),False)),('编辑',edit),('删除',lambda:store.delete(selected()))]:ttk.Button(bar,text=title,command=lambda f=fn:invoke(f)).pack(side='left',padx=3)
        window.protocol('WM_DELETE_WINDOW',lambda:(store.close(),window.destroy()));refresh()
        window.transient(self.root);window.grab_set();self.root.wait_window(window)
    def draw_wave(self):
        self.canvas.delete('wave')
        if not self.project or not self.wave:return
        width=max(1,self.canvas.winfo_width());height=92;timeline=self.timeline()
        if not timeline.duration:return
        for x in range(0,width,2):
            tick=x*timeline.duration//width;source=timeline.source_at(tick)
            if source is None:continue
            i=min(len(self.wave)-1,source*len(self.wave)//self.project.source.duration);amp=self.wave[i]*40
            self.canvas.create_line(x,height/2-amp,x,height/2+amp,fill='#397a9a',tags='wave')
        self.draw_cursor()
    def draw_cursor(self):
        self.canvas.delete('cursor')
        if self.project and self.timeline().duration:
            x=self.player.position*self.canvas.winfo_width()/self.timeline().duration
            self.canvas.create_line(x,0,x,92,fill='#d96635',width=2,tags='cursor')
    def seek_wave(self,event):
        if not self.busy and self.project:self.player.seek(min(self.timeline().duration,int(event.x*self.timeline().duration/max(1,self.canvas.winfo_width()))))
    def close(self):
        if self.busy:
            if boxes.askyesno('关闭工具','任务仍在运行。取消任务并关闭？当前编辑将先询问保存。',parent=self.root):
                self.closing=True;self.cancel()
            return
        self.finish_close()
    def finish_close(self):
        self.closing=False
        if not self.discard():return
        self.player.stop();self.runtime.close();self.root.destroy()


def main():
    root=tk.Tk();Workspace(root);root.mainloop()
