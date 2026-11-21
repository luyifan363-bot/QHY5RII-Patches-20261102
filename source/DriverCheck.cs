using System;
using System.IO;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Text;
class DriverCheck {
    const string ProgId="ASCOM.QHY5RII.FastTransition.Camera";
    [STAThread] static int Main(string[] args) {
        var report=new Dictionary<string,object>{{"status","starting"}};object instance=null;dynamic camera=null;int code=1;
        try {
            if(args.Length!=3) throw new Exception("Use metadata/com, target DLL and report path");
            if(IntPtr.Size!=4) throw new Exception("x86 process required");
            var assembly=Assembly.LoadFile(Path.GetFullPath(args[1]));var name=assembly.GetName();
            if(name.Name!=ProgId || name.Version.ToString()!="25.3.24.1001" || name.GetPublicKey().Length==0 || assembly.ImageRuntimeVersion!="v4.0.30319") throw new Exception("Unexpected separate driver identity");
            var type=assembly.GetType("ASCOM.QHYCCD.Camera",true);
            if(type.GUID!=new Guid("d54d716c-9c15-4fde-b034-bb54cb4d3021")) throw new Exception("Unexpected camera CLSID");
            var flags=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static|BindingFlags.Instance;
            var helper=type.GetMethod("PrepareQhy5RiiExposureTransition",flags);if(helper==null) throw new Exception("Patch helper missing");
            report["assembly"]=assembly.FullName;report["runtime"]=assembly.ImageRuntimeVersion;report["clsid"]=type.GUID.ToString();
            if(args[0]=="metadata") {
                instance=FormatterServices.GetUninitializedObject(type);var common=assembly.GetType("ASCOM.QHYCCD.Common",true);
                foreach(var row in new[]{new object[]{"OTHER_CAMERA",1.0,2.0,new IntPtr(1)},new object[]{"QHY5RII-C-test",1.0,1.0,new IntPtr(1)},new object[]{"QHY5RII-C-test",-1.0,2.0,new IntPtr(1)},new object[]{"QHY5RII-C-second-device",1.0,2.0,IntPtr.Zero}}) {
                    common.GetField("camid",flags).SetValue(null,new StringBuilder((string)row[0]));common.GetField("camhandle",flags).SetValue(null,row[3]);type.GetField("cameraLastExposureDuration",flags).SetValue(instance,row[1]);helper.Invoke(instance,new[]{row[2]});
                    if(Convert.ToInt32(type.GetField("qhyFastTransitionCancelAttempts",flags).GetValue(instance))!=0) throw new Exception("Guard regression");
                }
                report["guard_checks"]=4;
            } else if(args[0]=="com") {
                camera=Activator.CreateInstance(Type.GetTypeFromProgID(ProgId,true));
                report["interface_version"]=Convert.ToInt32(camera.InterfaceVersion);report["driver_version"]=Convert.ToString(camera.DriverVersion);
                if(Convert.ToInt32(camera.InterfaceVersion)!=3 || Convert.ToBoolean(camera.Connected)) throw new Exception("Unexpected initial COM state");
                report["com_activation"]=true;report["camera_connected_for_test"]=false;
            } else throw new Exception("Unknown check mode");
            report["status"]="passed";code=0;
        }catch(Exception error){report["status"]="failed";report["error"]=error.ToString();Console.Error.WriteLine(error.Message);}
        finally {
            if(camera!=null){try{camera.Dispose();}catch(Exception error){report["dispose_note"]=error.Message;}try{if(Marshal.IsComObject(camera))Marshal.FinalReleaseComObject(camera);}catch{}}
            if(args.Length==3)File.WriteAllText(args[2],new JavaScriptSerializer().Serialize(report));
        }
        return code;
    }
}
