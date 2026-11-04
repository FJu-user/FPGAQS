"""Rebuild the delivered project with Python 3 and Anlogic TD 6.2.
Outputs go to a fresh directory; verified delivery files are never overwritten.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,re,shutil,subprocess

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--td',help='Path to td_commands_prompt.exe')
 ap.add_argument('--project',type=Path,default=Path(__file__).resolve().parent)
 ap.add_argument('--work',type=Path)
 ap.add_argument('--prepare-only',action='store_true')
 args=ap.parse_args();root=args.project.resolve();templates=root/'build_templates'
 assert templates.is_dir(),templates
 work=(args.work or root/('rebuild_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))).resolve()
 work.mkdir(parents=True,exist_ok=False)
 project=root/'td_project/camera_to_dsi_display.al'
 al=project.read_text(encoding='utf-8')
 al=re.sub(r'(<Project\s[^>]*\bPath=")[^"]*',lambda m:m[1]+work.as_posix(),al,count=1)
 def absolute_source(match):
  path=(project.parent/match[1]).resolve();assert path.is_file() and path.is_relative_to(root),path
  return '<File Path="'+path.as_posix()+'"'
 al=re.sub(r'<File Path="([^"]+)"',absolute_source,al)
 native_project=work/project.name;native_project.write_text(al,encoding='utf-8')
 hdl=root/'user_source/hdl_source'
 for p in hdl.iterdir():
  if p.is_file() and p.suffix in ('.hex','.dath'):shutil.copyfile(p,work/p.name)
 shutil.copyfile(hdl/'ph1p35_ddr/ddr2/src/rtl/phy/ddrphy_cfg_rom.txt',work/'ddrphy_cfg_rom.txt')
 for p in templates.iterdir():
  if p.is_file():
   text=p.read_text(encoding='utf-8').replace('@PROJECT_ROOT@',root.as_posix()).replace('@WORK@',work.as_posix())
   text=text.replace(project.as_posix(),native_project.as_posix())
   text=text.replace('cd {'+project.parent.as_posix()+'}','cd {'+work.as_posix()+'}')
   assert '@PROJECT_ROOT@' not in text and '@WORK@' not in text
   (work/p.name).write_text(text,encoding='utf-8')
 source_extensions=('.v','.sv','.vh','.hex','.dath','.txt','.xml','.sdc','.adc','.tcl')
 sources=[p for p in (root/'user_source').rglob('*') if p.is_file() and p.suffix in source_extensions]
 sources += [root/'td_project/camera_to_dsi_display.al',root/'td_project/camera_to_dsi_display.sdc']
 input_hashes={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
 (work/'INPUT_SHA256.json').write_text(json.dumps(input_hashes,indent=2),encoding='utf-8')
 if args.prepare_only:
  print('PREPARED only; no synthesis, route or bitgen:',work);return
 td=args.td or shutil.which('td_commands_prompt.exe')
 if not td and shutil.which('td'):td=str(Path(shutil.which('td')).parent/'td_commands_prompt.exe')
 if not td or not Path(td).is_file():raise RuntimeError('Use --td to select Anlogic TD td_commands_prompt.exe')
 def stage(name,marker):
  print('START',name,flush=True)
  with (work/(name+'.log')).open('w',encoding='utf-8') as stream:
   process=subprocess.run([td,name+'.tcl'],cwd=work,stdout=stream,stderr=subprocess.STDOUT,timeout=14400)
  log=(work/(name+'.log')).read_text(encoding='utf-8',errors='replace')
  if process.returncode or marker not in log or re.search(r'\bERROR:|\bFATAL:',log):raise RuntimeError('Stage failed; inspect '+str(work/(name+'.log')))
  print('PASS',name,flush=True)
  return log
 stage('gate','FRAME_GATE_COMPLETE');stage('physical','ROUTE_COMPLETE')
 assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in input_hashes.items()),'Project inputs changed during implementation'
 values={k:float(re.search(k+r':\s*(-?[\d.]+)ns',(work/'routed.ts').read_text())[1]) for k in ('SWNS','STNS','HWNS','HTNS')}
 assert values['SWNS']>=0 and values['HWNS']>=0 and values['STNS']==values['HTNS']==0,values
 area=(work/'routed.area').read_text()
 for name in ('slice','eram','dsp','pll'):
  m=re.search(r'^#'+name+r'\s+(\d+)\s+out of\s+(\d+)',area,re.M);assert m and int(m[1])<=int(m[2]),name
 stage('cdc','CDC_AUDIT_COMPLETE')
 for name,count in [('gray',32),('forward_bundle',270),('camera_time',20),('pixel_time',40),('isp_bundle',41),('key_bundle',6)]:
  t=(work/(name+'.timing')).read_text()
  m=re.search(r'Max\s+: SWNS\s+(-?[\d.]+)ns, STNS\s+(-?[\d.]+)ns,\s+(\d+) Viol Endpoints,\s+(\d+) Total Endpoints,\s+(\d+) Paths Analyzed',t)
  assert m and float(m[1])>=0 and float(m[2])==0 and int(m[3])==0 and int(m[4])==int(m[5])==count,(name,'CDC budget or collection changed')
 if (work/'storage.tcl').exists():
  stage('storage','STORAGE_CONTROL_COMPLETE')
  for name in ('all','reset'):
   text=(work/(name+'.timing')).read_text()
   rows=re.findall(r'^(Max|Min)\s+:\s+[SH]WNS\s+(-?[\d.]+)ns,\s+[SH]TNS\s+(-?[\d.]+)ns,\s+(\d+) Viol Endpoints,\s+(\d+) Total Endpoints,\s+(\d+) Paths Analyzed',text,re.M)
   assert rows and {row[0] for row in rows}=={'Max','Min'}
   assert all(float(a)>=0 and float(b)==0 and int(c)==0 and int(d)==int(e)>0 for k,a,b,c,d,e in rows),(name,'storage controls failed')
 log=stage('export','SIGNOFF_EXPORT_COMPLETE')
 assert 'No multi-drive.' in log and 'No abnormal timing path.' in log
 bits=list(work.glob('*.bit'));assert bits
 result=dict(timing_ns=values,bits={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in bits},hardware_programmed=False,rtl_regression_run_by_this_script=False)
 (work/'REBUILD_RESULT.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 print('Rebuild complete. RTL regression and hardware acceptance remain separate:',work)

if __name__=='__main__':main()
