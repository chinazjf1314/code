#! /bin/bash

# 查找系统大页路径
# 1GB大小页
pagesize_1GB=1048576
# 512MB大小页
pagesize_512MB=524288
# 2MB大小页
pagesize_2MB=2048


for size in ${pagesize_1GB} ${pagesize_512MB} ${pagesize_2MB}; do
	path="/sys/kernel/mm/hugepages/hugepages-${size}kB"
	if [ -d "${path}" ];then
		nr_hugepages="${path}/nr_hugepages"
		free_hugepages="${path}/free_hugepages"
		size_hugepages=${size}
		break
	fi
done


KIB=$((8*1024))
MIB=$((${KIB}*1024))
GIB=$((${MIB}*1024))
message="/var/log/messages"
# 规格配置
# 虚拟机 osd 1GB uss 2GB
# 物理机 osd 2GB uss 3GB
declare -A cluster_map
if [ -z ${2} ];then
	cluster_map=([virtual_osd]=$((1*${GIB})) [virtual_uss]=$((2*${GIB})) [physics_osd]=$((2*${GIB})) [physics_uss]=$((3*${GIB})))
else
	cluster_map=([virtual_osd]=$((${2}*${MIB})) [virtual_uss]=$((${2}*${MIB})) [physics_osd]=$((${2}*${MIB})) [physics_uss]=$((${2}*${MIB})))
fi
productName=$(virt-what)

function osd_config(){
	# 物理机,虚拟机规格配置不同
	if [ -z $productName ];then
		# 物理机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['physics_osd']}
	else
		# 虚拟机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['virtual_osd']}
	fi
}

function uss_config(){
	if [ -z $productName ];then
		# 物理机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['physics_uss']}
	else
		# 虚拟机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['virtual_uss']}
	fi
}

case ${1} in
	"osd")
		osd_config productName
		;;
	"uss")
		uss_config productName
		;;
		*)
		echo "输入用途 hugepage.sh osd|uss"
		exit 1
		;;
esac

# echo $alloc_page_size


#系统剩余内存阈值限制
MemFreeLimit=$((${MIB}*200))
# 重试次数
RetryCount=3

function allocate_page()
{
	# 需要分配多少空间的大页内存
	need_page_size=${1}
	# 去除限额可分配的内存空间
	distributable=${2}

	# 可用空间大于需要分配空间进行分配
	if [ "${distributable}" -ge "${need_page_size}" ];then
		# 判断当前已有大页内存，在此基础上增加
		need_page=$((${need_page_size}/${pagesize}))
		already_page=$(cat ${nr_hugepages})
		alloc_page=$((${need_page}+${already_page}))
		echo "总页数 ${alloc_page}，新增加 ${need_page} 页" >> ${message}
		echo ${alloc_page} > ${nr_hugepages}
		total_alloc=$(cat ${nr_hugepages})
		success_alloc=$[${total_alloc}-${already_page}]
		unassigned=$((${need_page}-${success_alloc}))
		echo "**************************************" >> ${message}
		echo "成功分配 ${success_alloc}, 未分配 ${unassigned}" >> ${message}
		surplus_cache_size=$(($(grep -e "^MemFree" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
		surplus_alloc_page=$((${surplus_cache_size}/${pagesize}))
		grep HugePage /proc/meminfo >> ${message}
		echo "**************************************" >> ${message}
		echo "当前剩余内存" >> ${message}
		grep -e "^MemFree" /proc/meminfo >> ${message}
		echo "还可分配 ${surplus_alloc_page} 个 $((${pagesize}/${KIB})) KIB 大页内存。" >> ${message}
		echo "**************************************" >> ${message}
		return 0
	else
		need_cache_size=$((${need_page_size}-${distributable}))
		echo "系统可用内存空间不足，缺少 $((${need_cache_size}/${KIB})) KIB 内存空间。" >> ${message}
		echo "**************************************" >> ${message}
		return 1
	fi
}

#系统可用内存大小
MemFreeSize=$(($(grep -e "^MemFree" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
#每个大页大小
pagesize=$((${size_hugepages}*${KIB}))
#已有大页个数
pagecount=$(cat $free_hugepages)
#可用大页内存空间
HugepageFreeSize=$((${pagecount}*${pagesize}))

echo "**************************************" >> ${message}
# 系统可用大页内存不满足时，为节点新增加大页内存
if [ "${alloc_page_size}" -gt "${HugepageFreeSize}" ];then
        # 还差多少页需要分配
        need_page_size=$((${alloc_page_size}-${HugepageFreeSize}))
        # 每次需要分多少个页
	pagecount=$((${need_page_size}/${pagesize}))
        # echo "还需 $((${need_page_size}/${KIB})) KIB 页大小"
        # 去除限额可分配的内存空间
        distributable=$((${MemFreeSize}-${MemFreeLimit}))
	until [ "${RetryCount}" -eq "0" ];
	do
		starthugefree=$(cat $free_hugepages)
		#echo "start huge free ${starthugefree}"
		#echo "need page size ${need_page_size}, distributable ${distributable}, count ${pagecount}"
		allocate_page ${need_page_size} ${distributable}
		# 模拟分配过之后被别的进程占用
		# sleep 20
		endhugefree=$(cat $free_hugepages)
		#echo "end huge free ${endhugefree}"
		# 计算实际分配量
		hugefree=$[${endhugefree}-${starthugefree}]
		diffence_page=$[${pagecount}-${hugefree}]
		pagecount=${diffence_page}
		#echo "diffence page count $diffence_page"
		if [ "${diffence_page}" -eq "0" ];then
			break
		fi
		memfreesize=$(($(grep -e "^MemFree" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
		distributable=$[${memfreesize}-${MemFreeLimit}]
		need_page_size=$[${diffence_page}*${pagesize}]
		RetryCount=$[${RetryCount} -1]
	done
	if [ "${diffence_page}" -eq "0" ];then
		exit 0
	else
		# 重试之后还未分配完毕异常退出
		exit 1
	fi
else
        echo "系统已有$((${pagesize}/${KIB})) KIB 大页内存 ${pagecount} 个。" >> ${message}
        echo "**************************************" >> ${message}
        exit 0
fi