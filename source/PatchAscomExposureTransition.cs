using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Mono.Cecil;
using Mono.Cecil.Cil;

class PatchAscomExposureTransition {
    const string OriginalHash="4348F80FD2156C3E9A980100BC57AB67E5E874BECB84875C675FB894400F65F3";
    const string Target="QHY5RII-C-";
    static string Hash(string path) {using(var sha=SHA256.Create()) using(var s=File.OpenRead(path)) return BitConverter.ToString(sha.ComputeHash(s)).Replace("-","");}
    static void Main(string[] args) {
        if(args.Length!=2) throw new ArgumentException("Original DLL and isolated output DLL required");
        if(Path.GetFullPath(args[0]).Equals(Path.GetFullPath(args[1]),StringComparison.OrdinalIgnoreCase)) throw new Exception("An isolated output path is required");
        if(Hash(args[0])!=OriginalHash) throw new Exception("Unsupported original ASCOM build");
        using(var assembly=AssemblyDefinition.ReadAssembly(args[0])) {
            var module=assembly.MainModule;
            var camera=module.GetType("ASCOM.QHYCCD.Camera");
            var common=module.GetType("ASCOM.QHYCCD.Common");
            var native=module.GetType("ASCOM.QHYCCD.libqhyccd");
            var acquire=camera.Methods.Single(m=>m.Name=="GetOneFrame" && m.Parameters.Count==1);
            var last=camera.Fields.Single(f=>f.Name=="cameraLastExposureDuration");
            var id=common.Fields.Single(f=>f.Name=="camid");
            var handle=common.Fields.Single(f=>f.Name=="camhandle");
            var cancel=native.Methods.Single(m=>m.Name=="CancelQHYCCDExposingAndReadout");
            var attempts=new FieldDefinition("qhyFastTransitionCancelAttempts",FieldAttributes.Private,module.TypeSystem.Int32);
            var successes=new FieldDefinition("qhyFastTransitionCancelSuccesses",FieldAttributes.Private,module.TypeSystem.Int32);
            camera.Fields.Add(attempts);camera.Fields.Add(successes);
            var prepare=new MethodDefinition("PrepareQhy5RiiExposureTransition",MethodAttributes.Private|MethodAttributes.HideBySig,module.TypeSystem.Void);
            prepare.Parameters.Add(new ParameterDefinition("requestedDuration",ParameterAttributes.None,module.TypeSystem.Double));
            camera.Methods.Add(prepare);
            var il=prepare.Body.GetILProcessor();var done=Instruction.Create(OpCodes.Ret);
            il.Emit(OpCodes.Ldsfld,id);il.Emit(OpCodes.Brfalse,done);
            il.Emit(OpCodes.Ldsfld,id);il.Emit(OpCodes.Callvirt,module.ImportReference(typeof(object).GetMethod("ToString")));
            il.Emit(OpCodes.Ldstr,Target);il.Emit(OpCodes.Ldc_I4,(int)StringComparison.Ordinal);il.Emit(OpCodes.Callvirt,module.ImportReference(typeof(string).GetMethod("StartsWith",new[]{typeof(string),typeof(StringComparison)})));
            il.Emit(OpCodes.Brfalse,done);
            il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Ldfld,last);il.Emit(OpCodes.Ldc_R8,0.0);il.Emit(OpCodes.Ble_Un,done);
            il.Emit(OpCodes.Ldarg_1);il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Ldfld,last);il.Emit(OpCodes.Beq,done);
            il.Emit(OpCodes.Ldsfld,handle);il.Emit(OpCodes.Ldsfld,module.ImportReference(typeof(IntPtr).GetField("Zero")));il.Emit(OpCodes.Call,module.ImportReference(typeof(IntPtr).GetMethod("op_Equality",new[]{typeof(IntPtr),typeof(IntPtr)})));il.Emit(OpCodes.Brtrue,done);
            il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Dup);il.Emit(OpCodes.Ldfld,attempts);il.Emit(OpCodes.Ldc_I4_1);il.Emit(OpCodes.Add);il.Emit(OpCodes.Stfld,attempts);
            il.Emit(OpCodes.Ldsfld,handle);il.Emit(OpCodes.Call,cancel);il.Emit(OpCodes.Brtrue,done);
            il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Dup);il.Emit(OpCodes.Ldfld,successes);il.Emit(OpCodes.Ldc_I4_1);il.Emit(OpCodes.Add);il.Emit(OpCodes.Stfld,successes);
            il.Append(done);prepare.Body.MaxStackSize=4;
            var entry=acquire.Body.Instructions[0];var body=acquire.Body.GetILProcessor();
            body.InsertBefore(entry,Instruction.Create(OpCodes.Ldarg_0));body.InsertBefore(entry,Instruction.Create(OpCodes.Ldarg_1));body.InsertBefore(entry,Instruction.Create(OpCodes.Call,prepare));
            // Remove the vendor signing identity from the independent local build.
            // No machine-wide signature verification setting is changed.
            module.Attributes &= ~ModuleAttributes.StrongNameSigned;
            assembly.Name.PublicKey=new byte[0];
            assembly.Name.HasPublicKey=false;
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[1])));
            assembly.Write(args[1]);
        }
        using(var original=AssemblyDefinition.ReadAssembly(args[0])) using(var patched=AssemblyDefinition.ReadAssembly(args[1])) {
            if(original.Name.Name!=patched.Name.Name || original.Name.Version!=patched.Name.Version || patched.Name.HasPublicKey) throw new Exception("Unexpected local assembly identity");
            foreach(var type in original.MainModule.Types) {
                var changed=patched.MainModule.GetType(type.FullName);
                foreach(var method in type.Methods.Where(m=>m.HasBody)) {
                    var match=changed.Methods.Single(m=>m.FullName==method.FullName);
                    var oldCode=method.Body.Instructions.Select(i=>i.OpCode+" "+(i.Operand==null?"":i.Operand.ToString())).ToArray();
                    var newCode=match.Body.Instructions.Select(i=>i.OpCode+" "+(i.Operand==null?"":i.Operand.ToString())).ToArray();
                    if(method.Name=="GetOneFrame") {
                        // Branch target offsets all move by 7 bytes; compare opcode and semantic operands.
                        if(newCode.Length!=oldCode.Length+3) throw new Exception("Unexpected acquisition body change");
                        for(int i=0;i<oldCode.Length;i++) {
                            var before=method.Body.Instructions[i];var after=match.Body.Instructions[i+3];
                            if(before.OpCode!=after.OpCode) throw new Exception("Changed existing acquisition opcode");
                            if(before.Operand is Instruction) {
                                if(method.Body.Instructions.IndexOf((Instruction)before.Operand)!=match.Body.Instructions.IndexOf((Instruction)after.Operand)-3) throw new Exception("Changed acquisition branch target");
                            } else if(Convert.ToString(before.Operand)!=Convert.ToString(after.Operand)) throw new Exception("Changed existing acquisition operand");
                        }
                    } else if(!oldCode.SequenceEqual(newCode)) throw new Exception("Unexpected change outside GetOneFrame: "+method.FullName);
                }
            }
        }
        using(var memory=new MemoryStream(File.ReadAllBytes(args[1]))) using(var separate=AssemblyDefinition.ReadAssembly(memory)) {
            const string progid="ASCOM.QHY5RII.FastTransition.Camera";
            var module=separate.MainModule;var camera=module.GetType("ASCOM.QHYCCD.Camera");
            separate.Name.Name=progid;separate.Name.Version=new Version(25,3,24,1001);
            module.Name=progid+".dll";module.RuntimeVersion="v4.0.30319";module.Attributes|=ModuleAttributes.Required32Bit;
            var visibility=separate.CustomAttributes.FirstOrDefault(a=>a.AttributeType.FullName=="System.Runtime.InteropServices.ComVisibleAttribute");
            if(visibility==null) {visibility=new CustomAttribute(module.ImportReference(typeof(System.Runtime.InteropServices.ComVisibleAttribute).GetConstructor(new[]{typeof(bool)})));visibility.ConstructorArguments.Add(new CustomAttributeArgument(module.TypeSystem.Boolean,false));separate.CustomAttributes.Add(visibility);} else visibility.ConstructorArguments[0]=new CustomAttributeArgument(module.TypeSystem.Boolean,false);
            var assemblyGuid=separate.CustomAttributes.FirstOrDefault(a=>a.AttributeType.FullName=="System.Runtime.InteropServices.GuidAttribute");
            if(assemblyGuid!=null) assemblyGuid.ConstructorArguments[0]=new CustomAttributeArgument(module.TypeSystem.String,"876eb66a-d981-4517-aeb1-f7deca703d05");
            var visibleCamera=new CustomAttribute(module.ImportReference(typeof(System.Runtime.InteropServices.ComVisibleAttribute).GetConstructor(new[]{typeof(bool)})));
            visibleCamera.ConstructorArguments.Add(new CustomAttributeArgument(module.TypeSystem.Boolean,true));camera.CustomAttributes.Add(visibleCamera);
            var guid=camera.CustomAttributes.Single(a=>a.AttributeType.FullName=="System.Runtime.InteropServices.GuidAttribute");
            guid.ConstructorArguments[0]=new CustomAttributeArgument(module.TypeSystem.String,"d54d716c-9c15-4fde-b034-bb54cb4d3021");
            var attr=new CustomAttribute(module.ImportReference(typeof(System.Runtime.InteropServices.ProgIdAttribute).GetConstructor(new[]{typeof(string)})));
            attr.ConstructorArguments.Add(new CustomAttributeArgument(module.TypeSystem.String,progid));camera.CustomAttributes.Add(attr);
            var description=camera.Methods.Single(m=>m.Name==".cctor").Body.Instructions.Single(i=>i.OpCode==OpCodes.Ldstr && (string)i.Operand=="QHYCCD-Cameras-Capture");
            description.Operand="QHY5RII-C Fast Transition TEST";
            using(var rsa=new RSACryptoServiceProvider(2048,new CspParameters{Flags=CspProviderFlags.CreateEphemeralKey})) {
                rsa.PersistKeyInCsp=false;
                byte[] key=rsa.ExportCspBlob(true);
                separate.Name.PublicKey=new System.Reflection.StrongNameKeyPair(key).PublicKey;separate.Name.HasPublicKey=true;
                module.Attributes|=ModuleAttributes.StrongNameSigned;
                separate.Write(args[1],new WriterParameters{Timestamp=0,DeterministicMvid=true,StrongNameKeyBlob=key});
                Array.Clear(key,0,key.Length);
            }
        }
        Console.WriteLine("Original hash and unchanged acquisition verified; generated a separate x86 ASCOM driver with a new CLSID and ProgID.");
        Console.WriteLine("Candidate SHA256: "+Hash(args[1]));
    }
}
